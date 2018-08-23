# --
# Copyright (C) 2001-2018 OTRS AG, https://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see https://www.gnu.org/licenses/gpl-3.0.txt.
# --

package Kernel::Modules::AgentITSMChangeSearch;

use strict;
use warnings;

use Kernel::System::CustomerUser;
use Kernel::System::DynamicField;
use Kernel::System::DynamicField::Backend;
use Kernel::System::SearchProfile;
use Kernel::System::ITSMChange;
use Kernel::System::ITSMChange::ITSMWorkOrder;
use Kernel::System::CSV;
use Kernel::System::LinkObject;
use Kernel::System::Service;
use Kernel::System::VariableCheck qw(:all);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    # check needed objects
    for my $Object (
        qw(ParamObject DBObject LayoutObject LogObject UserObject GroupObject ConfigObject MainObject EncodeObject)
        )
    {
        if ( !$Self->{$Object} ) {
            $Self->{LayoutObject}->FatalError( Message => "Got no $Object!" );
        }
    }

    # create needed objects
    $Self->{CustomerUserObject}  = Kernel::System::CustomerUser->new(%Param);
    $Self->{DynamicFieldObject}  = Kernel::System::DynamicField->new(%Param);
    $Self->{BackendObject}       = Kernel::System::DynamicField::Backend->new(%Param);
    $Self->{SearchProfileObject} = Kernel::System::SearchProfile->new(%Param);
    $Self->{ChangeObject}        = Kernel::System::ITSMChange->new(%Param);
    $Self->{WorkOrderObject}     = Kernel::System::ITSMChange::ITSMWorkOrder->new(%Param);
    $Self->{CSVObject}           = Kernel::System::CSV->new(%Param);
    $Self->{LinkObject}          = Kernel::System::LinkObject->new(%Param);
    $Self->{ServiceObject}       = Kernel::System::Service->new(%Param);

    # get config for frontend
    $Self->{Config} = $Self->{ConfigObject}->Get("ITSMChange::Frontend::$Self->{Action}");

    # get the dynamic fields for this screen (change dynamic fields)
    $Self->{DynamicFieldChange} = $Self->{DynamicFieldObject}->DynamicFieldListGet(
        Valid       => 1,
        ObjectType  => 'ITSMChange',
        FieldFilter => $Self->{Config}->{DynamicField} || {},
    );

    # get the dynamic fields for this screen (workorder dynamic fields)
    $Self->{DynamicFieldWorkOrder} = $Self->{DynamicFieldObject}->DynamicFieldListGet(
        Valid       => 1,
        ObjectType  => 'ITSMWorkOrder',
        FieldFilter => $Self->{Config}->{DynamicField} || {},
    );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get confid data
    $Self->{StartHit} = int( $Self->{ParamObject}->GetParam( Param => 'StartHit' ) || 1 );
    $Self->{SearchLimit} = $Self->{Config}->{SearchLimit} || 500;
    $Self->{SortBy} = $Self->{ParamObject}->GetParam( Param => 'SortBy' )
        || $Self->{Config}->{'SortBy::Default'}
        || 'ChangeID';
    $Self->{OrderBy} = $Self->{ParamObject}->GetParam( Param => 'OrderBy' )
        || $Self->{Config}->{'Order::Default'}
        || 'Down';
    $Self->{Profile}        = $Self->{ParamObject}->GetParam( Param => 'Profile' )        || '';
    $Self->{SaveProfile}    = $Self->{ParamObject}->GetParam( Param => 'SaveProfile' )    || '';
    $Self->{TakeLastSearch} = $Self->{ParamObject}->GetParam( Param => 'TakeLastSearch' ) || '';
    $Self->{SelectTemplate} = $Self->{ParamObject}->GetParam( Param => 'SelectTemplate' ) || '';
    $Self->{EraseTemplate}  = $Self->{ParamObject}->GetParam( Param => 'EraseTemplate' )  || '';

    # check request
    if ( $Self->{ParamObject}->GetParam( Param => 'SearchTemplate' ) && $Self->{Profile} ) {

        return $Self->{LayoutObject}->Redirect(
            OP =>
                "Action=AgentITSMChangeSearch;Subaction=Search;TakeLastSearch=1;SaveProfile=1;Profile=$Self->{Profile}"
        );
    }

    # get single params
    my %GetParam;

    # load parameters from search profile,
    # this happens when the next result page should be shown, or when the results are reordered
    if ( ( $Self->{Subaction} eq 'LoadProfile' && $Self->{Profile} ) || $Self->{TakeLastSearch} ) {
        %GetParam = $Self->{SearchProfileObject}->SearchProfileGet(
            Base      => 'ITSMChangeSearch',
            Name      => $Self->{Profile},
            UserLogin => $Self->{UserLogin},
        );
    }
    else {

        # get scalar search params
        for my $ParamName (
            qw(
            ChangeNumber ChangeTitle Description Justification
            CABCustomer
            CABAgent
            WorkOrderTitle WorkOrderInstruction WorkOrderReport ResultForm
            RequestedTimeSearchType PlannedStartTimeSearchType PlannedEndTimeSearchType
            ActualStartTimeSearchType ActualEndTimeSearchType CreateTimeSearchType
            ChangeTimeSearchType
            )
            )
        {
            $GetParam{$ParamName} = $Self->{ParamObject}->GetParam( Param => $ParamName );

            # remove whitespace on the start and end
            if ( $GetParam{$ParamName} ) {
                $GetParam{$ParamName} =~ s{ \A \s+ }{}xms;
                $GetParam{$ParamName} =~ s{ \s+ \z }{}xms;
            }
        }

        # get array search params
        for my $SearchParam (
            qw( ChangeStateIDs
            ChangeManagerIDs ChangeBuilderIDs
            PriorityIDs CategoryIDs ImpactIDs
            CreateBy
            WorkOrderStateIDs WorkOrderTypeIDs WorkOrderAgentIDs
            )
            )
        {
            my @Array = $Self->{ParamObject}->GetArray( Param => $SearchParam );
            if (@Array) {
                $GetParam{$SearchParam} = \@Array;
            }
        }

        # get time related params
        for my $TimeType (
            qw( Requested PlannedStart PlannedEnd ActualStart ActualEnd Create Change )
            )
        {

            # get time params fields
            my @Array = $Self->{ParamObject}->GetArray( Param => $TimeType . 'TimeSearchType' );
            if (@Array) {
                for my $Item (@Array) {
                    $GetParam{ $TimeType . $Item . 'Field' } = 1;
                }
            }

            # get time params details
            for my $Part (
                qw(
                PointFormat Point PointStart
                Start StartDay StartMonth StartYear
                Stop  StopDay  StopMonth  StopYear
                )
                )
            {
                my $ParamKey = "${TimeType}Time${Part}";
                my $ParamVal = $Self->{ParamObject}->GetParam( Param => $ParamKey );

                # remove white space on the start and end
                if ($ParamVal) {
                    $ParamVal =~ s{ \A \s+ }{}xms;
                    $ParamVal =~ s{ \s+ \z }{}xms;
                }

                # store in %GetParam
                $GetParam{$ParamKey} = $ParamVal;
            }
        }

        # get Dynamic fields from param object
        # cycle trough the activated Dynamic Fields for this screen
        DYNAMICFIELD:
        for my $DynamicFieldConfig (
            @{ $Self->{DynamicFieldChange} },
            @{ $Self->{DynamicFieldWorkOrder} }
            )
        {
            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

            # get search field preferences
            my $SearchFieldPreferences = $Self->{BackendObject}->SearchFieldPreferences(
                DynamicFieldConfig => $DynamicFieldConfig,
            );

            next DYNAMICFIELD if !IsArrayRefWithData($SearchFieldPreferences);

            PREFERENCE:
            for my $Preference ( @{$SearchFieldPreferences} ) {

                # extract the dynamic field value from the web request
                my $DynamicFieldValue = $Self->{BackendObject}->SearchFieldValueGet(
                    DynamicFieldConfig     => $DynamicFieldConfig,
                    ParamObject            => $Self->{ParamObject},
                    ReturnProfileStructure => 1,
                    LayoutObject           => $Self->{LayoutObject},
                    Type                   => $Preference->{Type},
                );

                # set the complete value structure in GetParam to store it later in the search profile
                if ( IsHashRefWithData($DynamicFieldValue) ) {
                    %GetParam = ( %GetParam, %{$DynamicFieldValue} );
                }
            }
        }
    }

    # set result form env
    if ( !$GetParam{ResultForm} ) {
        $GetParam{ResultForm} = '';
    }

    # show result site or perform other actions
    if ( $Self->{Subaction} eq 'Search' && !$Self->{EraseTemplate} ) {

        # fill up profile name (e.g. with last-search)
        if ( !$Self->{Profile} || !$Self->{SaveProfile} ) {
            $Self->{Profile} = 'last-search';
        }

        # save search profile (under last-search or real profile name)
        $Self->{SaveProfile} = 1;

        # remember last search values
        if ( $Self->{SaveProfile} && $Self->{Profile} ) {

            # remove old profile stuff
            $Self->{SearchProfileObject}->SearchProfileDelete(
                Base      => 'ITSMChangeSearch',
                Name      => $Self->{Profile},
                UserLogin => $Self->{UserLogin},
            );

            # insert new profile params
            for my $Key ( sort keys %GetParam ) {
                if ( $GetParam{$Key} ) {
                    $Self->{SearchProfileObject}->SearchProfileAdd(
                        Base      => 'ITSMChangeSearch',
                        Name      => $Self->{Profile},
                        Key       => $Key,
                        Value     => $GetParam{$Key},
                        UserLogin => $Self->{UserLogin},
                    );
                }
            }
        }

        # prepare CABAgents and CABCustomers
        if ( $GetParam{CABAgent} ) {
            $GetParam{CABAgents} = [ $GetParam{CABAgent} ];
        }
        if ( $GetParam{CABCustomer} ) {
            $GetParam{CABCustomers} = [ $GetParam{CABCustomer} ];
        }

        # store last queue screen
        my $URL = "Action=AgentITSMChangeSearch;Subaction=Search;Profile=$Self->{Profile};SortBy=$Self->{SortBy}"
            . ";OrderBy=$Self->{OrderBy};TakeLastSearch=1;StartHit=$Self->{StartHit}";
        $Self->{SessionObject}->UpdateSessionID(
            SessionID => $Self->{SessionID},
            Key       => 'LastScreenChanges',
            Value     => $URL,
        );
        $Self->{SessionObject}->UpdateSessionID(
            SessionID => $Self->{SessionID},
            Key       => 'LastChangeView',
            Value     => $URL,
        );

        # get and check the time search parameters
        TIMETYPE:
        for my $TimeType (
            qw( Requested PlannedStart PlannedEnd ActualStart ActualEnd Create Change )
            )
        {

            # extract the time search parameters for $TimeType into %TimeSelectionParam
            my %TimeSelectionParam;
            for my $Part (
                qw(
                SearchType
                PointFormat Point PointStart
                Start StartDay StartMonth StartYear
                Stop  StopDay  StopMonth  StopYear
                )
                )
            {
                $TimeSelectionParam{$Part} = $GetParam{ $TimeType . 'Time' . $Part };
            }

            # nothing to do, when no time search type has been selected
            next TIMETYPE if !$TimeSelectionParam{SearchType};

            if ( $TimeSelectionParam{SearchType} eq 'TimeSlot' ) {

                my %SystemTime;    # used for checking the ordering of the two times

                # the earlier limit
                if (
                    $TimeSelectionParam{StartDay}
                    && $TimeSelectionParam{StartMonth}
                    && $TimeSelectionParam{StartYear}
                    )
                {

                    # format as timestamp
                    $GetParam{ $TimeType . 'TimeNewerDate' } = sprintf
                        '%04d-%02d-%02d 00:00:00',
                        $TimeSelectionParam{StartYear},
                        $TimeSelectionParam{StartMonth},
                        $TimeSelectionParam{StartDay};
                }

                # the later limit
                if (
                    $TimeSelectionParam{StopDay}
                    && $TimeSelectionParam{StopMonth}
                    && $TimeSelectionParam{StopYear}
                    )
                {

                    # format as timestamp
                    $GetParam{ $TimeType . 'TimeOlderDate' } = sprintf
                        '%04d-%02d-%02d 23:59:59',
                        $TimeSelectionParam{StopYear},
                        $TimeSelectionParam{StopMonth},
                        $TimeSelectionParam{StopDay};
                }
            }
            elsif ( $TimeSelectionParam{SearchType} eq 'TimePoint' ) {

                # queries relative to now
                if (
                    $TimeSelectionParam{Point}
                    && $TimeSelectionParam{PointStart}
                    && $TimeSelectionParam{PointFormat}
                    )
                {
                    my $DiffSeconds = 0;
                    if ( $TimeSelectionParam{PointFormat} eq 'minute' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60;
                    }
                    elsif ( $TimeSelectionParam{PointFormat} eq 'hour' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60 * 60;
                    }
                    elsif ( $TimeSelectionParam{PointFormat} eq 'day' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60 * 60 * 24;
                    }
                    elsif ( $TimeSelectionParam{PointFormat} eq 'week' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60 * 60 * 24 * 7;
                    }
                    elsif ( $TimeSelectionParam{PointFormat} eq 'month' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60 * 60 * 24 * 30;
                    }
                    elsif ( $TimeSelectionParam{PointFormat} eq 'year' ) {
                        $DiffSeconds = $TimeSelectionParam{Point} * 60 * 60 * 24 * 365;
                    }

                    my $CurrentSystemTime = $Self->{TimeObject}->SystemTime();
                    my $CurrentTimeStamp  = $Self->{TimeObject}->SystemTime2TimeStamp(
                        SystemTime => $CurrentSystemTime
                    );
                    if ( $TimeSelectionParam{PointStart} eq 'Before' ) {

                        # search in the future
                        my $SearchTimeStamp = $Self->{TimeObject}->SystemTime2TimeStamp(
                            SystemTime => $CurrentSystemTime + $DiffSeconds,
                        );
                        $GetParam{ $TimeType . 'TimeNewerDate' } = $CurrentTimeStamp;
                        $GetParam{ $TimeType . 'TimeOlderDate' } = $SearchTimeStamp;
                    }
                    else {
                        my $SearchTimeStamp = $Self->{TimeObject}->SystemTime2TimeStamp(
                            SystemTime => $CurrentSystemTime - $DiffSeconds,
                        );
                        $GetParam{ $TimeType . 'TimeNewerDate' } = $SearchTimeStamp;
                        $GetParam{ $TimeType . 'TimeOlderDate' } = $CurrentTimeStamp;
                    }
                }
            }
            else {

                # unknown search types are simply ignored
            }
        }

        # search for substrings by default
        for my $Field (
            qw(ChangeTitle WorkOrderTitle Description Justification
            WorkOrderInstruction WorkOrderReport
            )
            )
        {
            if ( defined( $GetParam{$Field} ) && $GetParam{$Field} ne '' ) {
                $GetParam{$Field} = "*$GetParam{$Field}*";
            }
        }

        # dynamic fields search parameters for ticket search
        my %DynamicFieldSearchParameters;

        # cycle trough the activated Dynamic Fields for this screen
        DYNAMICFIELD:
        for my $DynamicFieldConfig (
            @{ $Self->{DynamicFieldChange} },
            @{ $Self->{DynamicFieldWorkOrder} }
            )
        {
            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

            # get search field preferences
            my $SearchFieldPreferences = $Self->{BackendObject}->SearchFieldPreferences(
                DynamicFieldConfig => $DynamicFieldConfig,
            );

            next DYNAMICFIELD if !IsArrayRefWithData($SearchFieldPreferences);

            PREFERENCE:
            for my $Preference ( @{$SearchFieldPreferences} ) {

                # extract the dynamic field value from the profile
                my $SearchParameter = $Self->{BackendObject}->SearchFieldParameterBuild(
                    DynamicFieldConfig => $DynamicFieldConfig,
                    Profile            => \%GetParam,
                    LayoutObject       => $Self->{LayoutObject},
                    Type               => $Preference->{Type},
                );

                # set search parameter
                if ( defined $SearchParameter ) {
                    $DynamicFieldSearchParameters{ 'DynamicField_' . $DynamicFieldConfig->{Name} }
                        = $SearchParameter->{Parameter};
                }
            }
        }

        # perform change search
        my $ViewableChangeIDs = $Self->{ChangeObject}->ChangeSearch(
            Result           => 'ARRAY',
            OrderBy          => [ $Self->{SortBy} ],
            OrderByDirection => [ $Self->{OrderBy} ],
            Limit            => $Self->{SearchLimit},
            MirrorDB         => 1,
            UserID           => $Self->{UserID},
            %GetParam,
            %DynamicFieldSearchParameters,
        );

        # CSV output
        if ( $GetParam{ResultForm} eq 'CSV' ) {
            my @CSVHead;
            my @CSVData;

            # get all change dynamic fields that are configured for the search csv output
            my %FieldFilter;
            FIELD:
            for my $Field ( @{ $Self->{Config}->{SearchCSVData} } ) {
                if ( $Field =~ m{ \A DynamicField_ ( [a-zA-Z\d]+ ) \z }xms ) {
                    $FieldFilter{$1} = 1;
                }
            }

            # get all dynamic fields for ITSMChange with the selected field filter
            my $DynamicFieldsITSMChange = $Self->{DynamicFieldObject}->DynamicFieldListGet(
                Valid       => 1,
                ObjectType  => 'ITSMChange',
                FieldFilter => \%FieldFilter,
            );

            ID:
            for my $ChangeID ( @{$ViewableChangeIDs} ) {

                # to store data of sub-elements
                my %SubElementData;

                # get change data
                my $Change = $Self->{ChangeObject}->ChangeGet(
                    UserID   => $Self->{UserID},
                    ChangeID => $ChangeID,
                );

                next ID if !$Change;

                # to store all data
                my %Info = %{$Change};

                # get user data for needed user types
                USERTYPE:
                for my $UserType (qw(ChangeBuilder ChangeManager WorkOrderAgent)) {

                    # check if UserType attribute exists either in change or workorder
                    if ( !$Change->{ $UserType . 'ID' } && !$Info{ $UserType . 'ID' } ) {
                        next USERTYPE;
                    }

                    # get user data
                    my %User = $Self->{UserObject}->GetUserData(
                        UserID =>
                            $Change->{ $UserType . 'ID' } || $Info{ $UserType . 'ID' },
                        Cached => 1,
                    );

                    # set user data
                    $Info{ $UserType . 'UserLogin' }        = $User{UserLogin};
                    $Info{ $UserType . 'UserFirstname' }    = $User{UserFirstname};
                    $Info{ $UserType . 'UserLastname' }     = $User{UserLastname};
                    $Info{ $UserType . 'LeftParenthesis' }  = '(';
                    $Info{ $UserType . 'RightParenthesis' } = ')';

                    # set user full name
                    $Info{$UserType} = $User{UserLogin} . ' (' . $User{UserFirstname}
                        . $User{UserLastname} . ')';
                }

                # to store the linked service data
                my $LinkListWithData = {};

                my @WorkOrderIDs;

                # store the combined linked services data from all workorders of this change
                @WorkOrderIDs = @{ $Change->{WorkOrderIDs} };

                # store the combined linked services data
                for my $WorkOrderID (@WorkOrderIDs) {

                    # get linked objects of this workorder
                    my $LinkListWithDataWorkOrder = $Self->{LinkObject}->LinkListWithData(
                        Object => 'ITSMWorkOrder',
                        Key    => $WorkOrderID,
                        State  => 'Valid',
                        UserID => $Self->{UserID},
                    );

                    OBJECT:
                    for my $Object ( sort keys %{$LinkListWithDataWorkOrder} ) {

                        # only show linked services of workorder
                        next OBJECT if $Object ne 'Service';

                        LINKTYPE:
                        for my $LinkType ( sort keys %{ $LinkListWithDataWorkOrder->{$Object} } ) {

                            DIRECTION:
                            for my $Direction (
                                sort keys %{ $LinkListWithDataWorkOrder->{$Object}->{$LinkType} }
                                )
                            {

                                ID:
                                for my $ID (
                                    sort keys %{
                                        $LinkListWithDataWorkOrder->{$Object}->{$LinkType}
                                            ->{$Direction}
                                    }
                                    )
                                {

                                    # combine the linked object data from all workorders
                                    $LinkListWithData->{$Object}->{$LinkType}->{$Direction}->{$ID}
                                        = $LinkListWithDataWorkOrder->{$Object}->{$LinkType}
                                        ->{$Direction}->{$ID};
                                }
                            }
                        }
                    }
                }

                # get unique service ids
                my %UniqueServiceIDs;
                my $ServicesRef = $LinkListWithData->{Service} || {};
                for my $LinkType ( sort keys %{$ServicesRef} ) {

                    # extract link type List
                    my $LinkTypeList = $ServicesRef->{$LinkType};

                    for my $Direction ( sort keys %{$LinkTypeList} ) {

                        # extract direction list
                        my $DirectionList = $ServicesRef->{$LinkType}->{$Direction};

                        # collect unique service ids
                        for my $ServiceID ( sort keys %{$DirectionList} ) {
                            $UniqueServiceIDs{$ServiceID}++;
                        }
                    }
                }

                # get the data for each service
                my @ServicesData;
                SERVICEID:
                for my $ServiceID ( sort keys %UniqueServiceIDs ) {

                    # get service data
                    my %ServiceData = $Self->{ServiceObject}->ServiceGet(
                        ServiceID => $ServiceID,
                        UserID    => $Self->{UserID},
                    );

                    # store service data
                    push @ServicesData, \%ServiceData;
                }

                # sort services data by service name
                @ServicesData = sort { $a->{Name} cmp $b->{Name} } @ServicesData;

                # store services data
                if ( scalar @ServicesData ) {
                    SERVICE:
                    for my $Service (@ServicesData) {
                        my $ServiceName = $Service->{NameShort};
                        if ( $Info{Services} ) {
                            $Info{Services} .= ' ' . $ServiceName;
                            next SERVICE;
                        }
                        $Info{Services} = $ServiceName;
                    }
                }

                # csv quote
                if ( !@CSVHead ) {
                    @CSVHead = @{ $Self->{Config}->{SearchCSVData} };
                }

                my @Data;
                for my $Header (@CSVHead) {

                    # if the column is a dynamic field
                    if ( $Header =~ m{ \A DynamicField_ ( [a-zA-Z\d]+ ) \z }xms ) {

                        my $DynamicFieldName = $1;

                        DYNAMICFIELD:
                        for my $DynamicFieldConfig ( @{$DynamicFieldsITSMChange} ) {

                            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);
                            next DYNAMICFIELD if $DynamicFieldConfig->{Name} ne $DynamicFieldName;

                            # get print string for this dynamic field
                            my $Value = $Self->{BackendObject}->DisplayValueRender(
                                DynamicFieldConfig => $DynamicFieldConfig,
                                Value              => $Info{$Header},
                                ValueMaxChars      => 100,
                                LayoutObject       => $Self->{LayoutObject},
                            );

                            $Info{$Header} = $Value->{Value};

                            last DYNAMICFIELD;
                        }
                    }

                    push @Data, $Info{$Header};
                }

                push @CSVData, \@Data;
            }

            # csv quote
            # translate non existing header may result in a garbage file
            if ( !@CSVHead ) {
                @CSVHead = @{ $Self->{Config}->{SearchCSVData} };
            }

            # translate headers
            for my $Header (@CSVHead) {

                # replace ChangeNumber header with the current ChangeHook from config
                if ( $Header eq 'ChangeNumber' ) {
                    $Header = $Self->{ConfigObject}->Get('ITSMChange::Hook');
                }
                else {
                    $Header = $Self->{LayoutObject}->{LanguageObject}->Translate($Header);
                }
            }

            # assable CSV data
            my $CSV = $Self->{CSVObject}->Array2CSV(
                Head      => \@CSVHead,
                Data      => \@CSVData,
                Separator => $Self->{UserCSVSeparator},
            );

            # return csv to download
            my $CSVFile = 'change_search';
            my ( $s, $m, $h, $D, $M, $Y ) = $Self->{TimeObject}->SystemTime2Date(
                SystemTime => $Self->{TimeObject}->SystemTime(),
            );
            $M = sprintf( "%02d", $M );
            $D = sprintf( "%02d", $D );
            $h = sprintf( "%02d", $h );
            $m = sprintf( "%02d", $m );
            return $Self->{LayoutObject}->Attachment(
                Filename    => $CSVFile . "_" . "$Y-$M-$D" . "_" . "$h-$m.csv",
                ContentType => "text/csv; charset=" . $Self->{LayoutObject}->{UserCharset},
                Content     => $CSV,
            );

        }
        elsif ( $GetParam{ResultForm} eq 'Print' ) {

            # to store all data
            my %Info;

            # to send data to the PDF output
            my @PDFData;
            ID:
            for my $ChangeID ( @{$ViewableChangeIDs} ) {

                # get change data
                my $Change = $Self->{ChangeObject}->ChangeGet(
                    UserID   => $Self->{UserID},
                    ChangeID => $ChangeID,
                );

                next ID if !$Change;

                # add change data,
                %Info = %{$Change};

                # get user data for needed user types
                USERTYPE:
                for my $UserType (qw(ChangeBuilder ChangeManager WorkOrderAgent)) {

                    # check if UserType attribute exists either in change or workorder
                    if ( !$Change->{ $UserType . 'ID' } && !$Info{ $UserType . 'ID' } ) {
                        next USERTYPE;
                    }

                    # get user data
                    my %User = $Self->{UserObject}->GetUserData(
                        UserID =>
                            $Change->{ $UserType . 'ID' } || $Info{ $UserType . 'ID' },
                        Cached => 1,
                    );

                    # set user full name
                    $Info{$UserType} = $User{UserLogin} . ' (' . $User{UserFirstname}
                        . $User{UserLastname} . ')';
                }

                use Kernel::System::PDF;
                $Self->{PDFObject} = Kernel::System::PDF->new( %{$Self} );
                if ( $Self->{PDFObject} ) {

                    my $ChangeTitle = $Self->{LayoutObject}->Output(
                        Template => '[% Data.ChangeTitle | truncate(30) | html %]',
                        Data     => \%Info,
                    );

                    my $PlannedStart = $Self->{LayoutObject}->Output(
                        Template => '[% Data.PlannedStartTime | Localize("TimeLong") %]',
                        Data     => \%Info,
                    );

                    my $PlannedEnd = $Self->{LayoutObject}->Output(
                        Template => '[% Data.PlannedEndTime | Localize("TimeLong") %]',
                        Data     => \%Info,
                    );

                    my @PDFRow;
                    push @PDFRow,  $Info{ChangeNumber};
                    push @PDFRow,  $ChangeTitle;
                    push @PDFRow,  $Info{ChangeBuilder};
                    push @PDFRow,  $Info{WorkOrderCount};
                    push @PDFRow,  $Info{ChangeState};
                    push @PDFRow,  $Info{Priority};
                    push @PDFRow,  $PlannedStart;
                    push @PDFRow,  $PlannedEnd;
                    push @PDFData, \@PDFRow;
                }
                else {

                    # add table block
                    $Self->{LayoutObject}->Block(
                        Name => 'Record',
                        Data => {
                            %Info,
                        },
                    );
                }
            }

            # PDF Output
            if ( $Self->{PDFObject} ) {
                my $Title = $Self->{LayoutObject}->{LanguageObject}->Translate('Change') . ' '
                    . $Self->{LayoutObject}->{LanguageObject}->Translate('Search');
                my $PrintedBy = $Self->{LayoutObject}->{LanguageObject}->Translate('printed by');
                my $Page      = $Self->{LayoutObject}->{LanguageObject}->Translate('Page');
                my $Time      = $Self->{LayoutObject}->{Time};

                # get maximum number of pages
                my $MaxPages = $Self->{ConfigObject}->Get('PDF::MaxPages');
                if ( !$MaxPages || $MaxPages < 1 || $MaxPages > 1000 ) {
                    $MaxPages = 100;
                }

                # create the header
                my $CellData;
                $CellData->[0]->[0]->{Content} = $Self->{ConfigObject}->Get('ITSMChange::Hook');
                $CellData->[0]->[0]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[1]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('ChangeTitle');
                $CellData->[0]->[1]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[2]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('ChangeBuilder');
                $CellData->[0]->[2]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[3]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('WorkOrders');
                $CellData->[0]->[3]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[4]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('ChangeState');
                $CellData->[0]->[4]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[5]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('Priority');
                $CellData->[0]->[5]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[6]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('PlannedStartTime');
                $CellData->[0]->[6]->{Font}    = 'ProportionalBold';
                $CellData->[0]->[7]->{Content} = $Self->{LayoutObject}->{LanguageObject}->Translate('PlannedEndTime');
                $CellData->[0]->[7]->{Font}    = 'ProportionalBold';

                # create the content array
                my $CounterRow = 1;
                for my $Row (@PDFData) {
                    my $CounterColumn = 0;
                    for my $Content ( @{$Row} ) {
                        $CellData->[$CounterRow]->[$CounterColumn]->{Content} = $Content;
                        $CounterColumn++;
                    }
                    $CounterRow++;
                }

                # output 'No ticket data found', if no content was given
                if ( !$CellData->[0]->[0] ) {
                    $CellData->[0]->[0]->{Content}
                        = $Self->{LayoutObject}->{LanguageObject}->Translate('No ticket data found.');
                }

                # page params
                my %PageParam;
                $PageParam{PageOrientation} = 'landscape';
                $PageParam{MarginTop}       = 30;
                $PageParam{MarginRight}     = 40;
                $PageParam{MarginBottom}    = 40;
                $PageParam{MarginLeft}      = 40;
                $PageParam{HeaderRight}     = $Title;
                $PageParam{FooterLeft}      = '';
                $PageParam{HeadlineLeft}    = $Title;
                $PageParam{HeadlineRight}   = $PrintedBy . ' '
                    . $Self->{UserFirstname} . ' '
                    . $Self->{UserLastname} . ' ('
                    . $Self->{UserEmail} . ') '
                    . $Time;

                # table params
                my %TableParam;
                $TableParam{CellData}            = $CellData;
                $TableParam{Type}                = 'Cut';
                $TableParam{FontSize}            = 6;
                $TableParam{Border}              = 0;
                $TableParam{BackgroundColorEven} = '#AAAAAA';
                $TableParam{BackgroundColorOdd}  = '#DDDDDD';
                $TableParam{Padding}             = 1;
                $TableParam{PaddingTop}          = 3;
                $TableParam{PaddingBottom}       = 3;

                # create new pdf document
                $Self->{PDFObject}->DocumentNew(
                    Title  => $Self->{ConfigObject}->Get('Product') . ': ' . $Title,
                    Encode => $Self->{LayoutObject}->{UserCharset},
                );

                # start table output
                $Self->{PDFObject}->PageNew(
                    %PageParam,
                    FooterRight => $Page . ' 1',
                );
                PAGE:
                for ( 2 .. $MaxPages ) {

                    # output table (or a fragment of it)
                    %TableParam = $Self->{PDFObject}->Table( %TableParam, );

                    # stop output or another page
                    if ( $TableParam{State} ) {
                        last PAGE;
                    }
                    else {
                        $Self->{PDFObject}->PageNew(
                            %PageParam, FooterRight => $Page
                                . ' '
                                . $_,
                        );
                    }
                }

                # return the pdf document
                my $Filename = 'change_search';
                my ( $s, $m, $h, $D, $M, $Y ) = $Self->{TimeObject}->SystemTime2Date(
                    SystemTime => $Self->{TimeObject}->SystemTime(),
                );
                $M = sprintf( "%02d", $M );
                $D = sprintf( "%02d", $D );
                $h = sprintf( "%02d", $h );
                $m = sprintf( "%02d", $m );
                my $PDFString = $Self->{PDFObject}->DocumentOutput();
                return $Self->{LayoutObject}->Attachment(
                    Filename    => $Filename . "_" . "$Y-$M-$D" . "_" . "$h-$m.pdf",
                    ContentType => "application/pdf",
                    Content     => $PDFString,
                    Type        => 'attachment',
                );
            }
            else {
                my $Output = $Self->{LayoutObject}->PrintHeader( Width => 800 );
                if ( @{$ViewableChangeIDs} == $Self->{SearchLimit} ) {
                    $Param{Warning} = '$Text{"Reached max. count of %s search hits!", "'
                        . $Self->{SearchLimit} . '"}';
                }
                $Output .= $Self->{LayoutObject}->Output(
                    TemplateFile => 'AgentITSMChangeSearchResultPrint',
                    Data         => \%Param,
                );

                # add footer
                $Output .= $Self->{LayoutObject}->PrintFooter();

                # return output
                return $Output;
            }

        }
        else {

            # start html page
            my $Output = $Self->{LayoutObject}->Header();
            $Output .= $Self->{LayoutObject}->NavigationBar();
            $Self->{LayoutObject}->Print( Output => \$Output );
            $Output = '';

            $Self->{Filter} = $Self->{ParamObject}->GetParam( Param => 'Filter' ) || '';
            $Self->{View}   = $Self->{ParamObject}->GetParam( Param => 'View' )   || '';

            # show changes
            my $LinkPage = 'Filter='
                . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{Filter} )
                . ';View=' . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{View} )
                . ';SortBy=' . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{SortBy} )
                . ';OrderBy='
                . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{OrderBy} )
                . ';Profile=' . $Self->{Profile} . ';TakeLastSearch=1;Subaction=Search'
                . ';';
            my $LinkSort = 'Filter='
                . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{Filter} )
                . ';View=' . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{View} )
                . ';Profile=' . $Self->{Profile} . ';TakeLastSearch=1;Subaction=Search'
                . ';';
            my $LinkFilter = 'TakeLastSearch=1;Subaction=Search;Profile='
                . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{Profile} )
                . ';';
            my $LinkBack = 'Subaction=LoadProfile;Profile='
                . $Self->{LayoutObject}->Ascii2Html( Text => $Self->{Profile} )
                . ';TakeLastSearch=1;';

            # find out which columns should be shown
            my @ShowColumns;
            if ( $Self->{Config}->{ShowColumns} ) {

                # get all possible columns from config
                my %PossibleColumn = %{ $Self->{Config}->{ShowColumns} };

                # get the column names that should be shown
                COLUMNNAME:
                for my $Name ( sort keys %PossibleColumn ) {
                    next COLUMNNAME if !$PossibleColumn{$Name};
                    push @ShowColumns, $Name;
                }
            }

            $Output .= $Self->{LayoutObject}->ITSMChangeListShow(
                ChangeIDs    => $ViewableChangeIDs,
                Total        => scalar @{$ViewableChangeIDs},
                View         => $Self->{View},
                Env          => $Self,
                LinkPage     => $LinkPage,
                LinkSort     => $LinkSort,
                LinkFilter   => $LinkFilter,
                LinkBack     => $LinkBack,
                Profile      => $Self->{Profile},
                TitleName    => 'Change Search Result',
                ShowColumns  => \@ShowColumns,
                SortBy       => $Self->{LayoutObject}->Ascii2Html( Text => $Self->{SortBy} ),
                OrderBy      => $Self->{LayoutObject}->Ascii2Html( Text => $Self->{OrderBy} ),
                RequestedURL => 'Action=' . $Self->{Action} . ';' . $LinkPage,
            );

            # build footer
            $Output .= $Self->{LayoutObject}->Footer();

            return $Output;
        }
    }
    elsif ( $Self->{Subaction} eq 'AJAXProfileDelete' ) {
        my $Profile = $Self->{ParamObject}->GetParam( Param => 'Profile' );

        # remove old profile stuff
        $Self->{SearchProfileObject}->SearchProfileDelete(
            Base      => 'ITSMChangeSearch',
            Name      => $Profile,
            UserLogin => $Self->{UserLogin},
        );
        my $Output = $Self->{LayoutObject}->JSONEncode(
            Data => 1,
        );
        return $Self->{LayoutObject}->Attachment(
            NoCache     => 1,
            ContentType => 'text/html',
            Content     => $Output,
            Type        => 'inline'
        );
    }
    elsif ( $Self->{Subaction} eq 'AJAX' ) {

        my $Output .= $Self->_MaskForm(
            %GetParam,
        );

        $Output .= $Self->{LayoutObject}->Output(
            TemplateFile => 'AgentITSMChangeSearch',
            Data         => \%Param,
        );
        return $Self->{LayoutObject}->Attachment(
            NoCache     => 1,
            ContentType => 'text/html',
            Content     => $Output,
            Type        => 'inline'
        );

    }

    # There was no 'SubAction', or there were validation errors, or an user or customer was searched
    # generate search mask
    my $Output = $Self->{LayoutObject}->Header();
    $Output .= $Self->{LayoutObject}->NavigationBar();

    $Self->{LayoutObject}->Block(
        Name => 'Search',
        Data => \%Param,
    );
    $Output .= $Self->{LayoutObject}->Output(
        TemplateFile => 'AgentITSMChangeSearch',
        Data         => \%Param,
    );
    $Output .= $Self->{LayoutObject}->Footer();

    return $Output;
}

sub _MaskForm {
    my ( $Self, %Param ) = @_;

    my $Profile = $Self->{ParamObject}->GetParam( Param => 'Profile' ) || '';
    my $EmptySearch = $Self->{ParamObject}->GetParam( Param => 'EmptySearch' );
    if ( !$Profile ) {
        $EmptySearch = 1;
    }
    my %GetParam = $Self->{SearchProfileObject}->SearchProfileGet(
        Base      => 'ITSMChangeSearch',
        Name      => $Profile,
        UserLogin => $Self->{UserLogin},
    );

    # allow profile overwrite the contents of %Param
    %Param = (
        %Param,
        %GetParam,
    );

    # set user friendly CABAgent field
    if ( $Param{CABAgent} && $Param{CABAgent} ne '' ) {

        # get user data
        my %UserData = $Self->{UserObject}->GetUserData(
            UserID => $Param{CABAgent},
        );

        # set user frenly CABAgent string
        my $UserValue = sprintf '"%s %s" <%s>',
            $UserData{UserFirstname},
            $UserData{UserLastname},
            $UserData{UserEmail};

        $Param{CABAgentSearch} = $UserValue;
    }

    # set user frendly CABCustomer field
    if ( $Param{CABCustomer} && $Param{CABCustomer} ne '' ) {

        # get customer data
        my %CustomerSearchList = $Self->{CustomerUserObject}->CustomerSearch(
            Search => $Param{CABCustomer},
        );
        $Param{CABCustomerSearch} = $CustomerSearchList{ $Param{CABCustomer} };
    }

    # set attributes string
    my @Attributes = (
        {
            Key   => 'ChangeNumber',
            Value => 'Change Number',
        },
        {
            Key   => 'ChangeTitle',
            Value => 'Change Title',
        },
        {
            Key   => 'WorkOrderTitle',
            Value => 'Work Order Title',
        },
        {
            Key   => 'CABAgent',
            Value => 'CAB Agent',
        },
        {
            Key   => 'CABCustomer',
            Value => 'CAB Customer',
        },
        {
            Key      => '',
            Value    => '-',
            Disabled => 1,
        },
        {
            Key   => 'Description',
            Value => 'Change Description',
        },
        {
            Key   => 'Justification',
            Value => 'Change Justification',
        },
        {
            Key   => 'WorkOrderInstruction',
            Value => 'WorkOrder Instruction',
        },
        {
            Key   => 'WorkOrderReport',
            Value => 'WorkOrder Report',
        },
    );

    my $DynamicFieldSeparator = 1;
    my $LastObjectType        = '';

    # create dynamic fields search options for attribute select
    # cycle trough the activated Dynamic Fields for this screen
    DYNAMICFIELD:
    for my $DynamicFieldConfig (
        @{ $Self->{DynamicFieldChange} },
        @{ $Self->{DynamicFieldWorkOrder} }
        )
    {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);
        next DYNAMICFIELD if !$DynamicFieldConfig->{Name};
        next DYNAMICFIELD if $DynamicFieldConfig->{Name} eq '';

        if (
            $LastObjectType eq 'ITSMChange'
            && $DynamicFieldConfig->{ObjectType} eq 'ITSMWorkOrder'
            )
        {
            $DynamicFieldSeparator = 1;
        }

        # save the last object type (needed for separator between change and workorder fields)
        $LastObjectType = $DynamicFieldConfig->{ObjectType};

        # create a separator for dynamic fields attributes
        if ($DynamicFieldSeparator) {
            push @Attributes, (
                {
                    Key      => '',
                    Value    => '-',
                    Disabled => 1,
                },
            );

            $DynamicFieldSeparator = 0;
        }

        # get search field preferences
        my $SearchFieldPreferences = $Self->{BackendObject}->SearchFieldPreferences(
            DynamicFieldConfig => $DynamicFieldConfig,
        );

        next DYNAMICFIELD if !IsArrayRefWithData($SearchFieldPreferences);

        # translate the dynamic field label
        my $TranslatedDynamicFieldLabel = $Self->{LayoutObject}->{LanguageObject}->Translate(
            $DynamicFieldConfig->{Label},
        );

        PREFERENCE:
        for my $Preference ( @{$SearchFieldPreferences} ) {

            # translate the suffix
            my $TranslatedSuffix = $Self->{LayoutObject}->{LanguageObject}->Translate(
                $Preference->{LabelSuffix},
            ) || '';

            if ($TranslatedSuffix) {
                $TranslatedSuffix = ' (' . $TranslatedSuffix . ')';
            }

            push @Attributes, (
                {
                    Key => 'Search_DynamicField_'
                        . $DynamicFieldConfig->{Name}
                        . $Preference->{Type},
                    Value => $TranslatedDynamicFieldLabel . $TranslatedSuffix,
                },
            );
        }
    }

    # create a separator if a dynamic field attribute was pushed
    if ( !$DynamicFieldSeparator ) {
        push @Attributes, (
            {
                Key      => '',
                Value    => '-',
                Disabled => 1,
            },
        );
    }

    # create HTML strings for all dynamic fields
    my %DynamicFieldHTML;

    # cycle trough the activated Dynamic Fields for this screen
    DYNAMICFIELD:
    for my $DynamicFieldConfig (
        @{ $Self->{DynamicFieldChange} },
        @{ $Self->{DynamicFieldWorkOrder} }
        )
    {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

        # get search field preferences
        my $SearchFieldPreferences = $Self->{BackendObject}->SearchFieldPreferences(
            DynamicFieldConfig => $DynamicFieldConfig,
        );

        next DYNAMICFIELD if !IsArrayRefWithData($SearchFieldPreferences);

        # get PossibleValues
        my $PossibleValues = $Self->{BackendObject}->PossibleValuesGet(
            DynamicFieldConfig   => $DynamicFieldConfig,
            OverridePossibleNone => 0,
        );

        PREFERENCE:
        for my $Preference ( @{$SearchFieldPreferences} ) {

            # get field html
            $DynamicFieldHTML{ $DynamicFieldConfig->{Name} . $Preference->{Type} }
                = $Self->{BackendObject}->SearchFieldRender(
                DynamicFieldConfig   => $DynamicFieldConfig,
                Profile              => \%GetParam,
                PossibleValuesFilter => $PossibleValues,
                DefaultValue =>
                    $Self->{Config}->{Defaults}->{DynamicField}
                    ->{ $DynamicFieldConfig->{Name} },
                LayoutObject => $Self->{LayoutObject},
                Type         => $Preference->{Type},
                );
        }
    }

    push @Attributes, (
        {
            Key   => 'PriorityIDs',
            Value => 'Change Priority',
        },
        {
            Key   => 'ImpactIDs',
            Value => 'Change Impact',
        },
        {
            Key   => 'CategoryIDs',
            Value => 'Change Category',
        },
        {
            Key   => 'ChangeStateIDs',
            Value => 'Change State',
        },
        {
            Key   => 'ChangeManagerIDs',
            Value => 'Change Manager',
        },
        {
            Key   => 'ChangeBuilderIDs',
            Value => 'Change Builder',
        },
        {
            Key   => 'CreateBy',
            Value => 'Created By',
        },
        {
            Key   => 'WorkOrderStateIDs',
            Value => 'WorkOrder State',
        },
        {
            Key   => 'WorkOrderTypeIDs',
            Value => 'WorkOrder Type',
        },
        {
            Key   => 'WorkOrderAgentIDs',
            Value => 'WorkOrder Agent',
        },
        {
            Key      => '',
            Value    => '-',
            Disabled => 1,
        },
    );

    # set time attributes
    my @TimeTypes = (
        {
            Prefix => 'Requested',
            Title  => 'Requested Date',
        },
        {
            Prefix => 'PlannedStart',
            Title  => 'PlannedStartTime',
        },
        {
            Prefix => 'PlannedEnd',
            Title  => 'PlannedEndTime',
        },
        {
            Prefix => 'ActualStart',
            Title  => 'ActualStartTime',
        },
        {
            Prefix => 'ActualEnd',
            Title  => 'ActualEndTime',
        },
        {
            Prefix => 'Create',
            Title  => 'CreateTime',
        },
        {
            Prefix => 'Change',
            Title  => 'ChangeTime',
        },
    );

    TIMETYPE:
    for my $TimeType (@TimeTypes) {
        my $Prefix = $TimeType->{Prefix};

        # show RequestedTime only when enabled in SysConfig
        if ( $Prefix eq 'Requested' && !$Self->{Config}->{RequestedTime} ) {
            next TIMETYPE;
        }

        my $Title                   = $Self->{LayoutObject}->{LanguageObject}->Translate( $TimeType->{Title} );
        my $BeforeAfterTranslatable = $Self->{LayoutObject}->{LanguageObject}->Translate('(before/after)');
        my $BetweenTranslatable     = $Self->{LayoutObject}->{LanguageObject}->Translate('(between)');
        push @Attributes, (
            {
                Key   => $Prefix . 'TimePointField',
                Value => $Title . " $BeforeAfterTranslatable",
            },
            {
                Key   => $Prefix . 'TimeSlotField',
                Value => $Title . " $BetweenTranslatable",
            },

        );
    }

    $Param{AttributesStrg} = $Self->{LayoutObject}->BuildSelection(
        Data     => \@Attributes,
        Name     => 'Attribute',
        Multiple => 0,
    );
    $Param{AttributesOrigStrg} = $Self->{LayoutObject}->BuildSelection(
        Data     => \@Attributes,
        Name     => 'AttributeOrig',
        Multiple => 0,
    );

    # Get a complete list of users
    # for the selection 'ChangeBuilder', 'ChangeManager' and 'created by user'.
    # It is important to also search for invalid agents, as we want to find
    # these changes too.
    # Out of office nice might be appended to the values.
    my %Users = $Self->{UserObject}->UserList(
        Type  => 'Long',
        Valid => 0,
    );

    # dropdown menu for 'created by users'
    $Param{'CreateBySelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => \%Users,
        Name       => 'CreateBy',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{CreateBy},
    );

    # build change manager dropdown
    $Param{'ChangeManagerSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => \%Users,
        Name       => 'ChangeManagerIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{ChangeManagerIDs},
    );

    # build change builder dropdown
    $Param{'ChangeBuilderSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => \%Users,
        Name       => 'ChangeBuilderIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{ChangeBuilderIDs},
    );

    # get possible Change Categories
    my $Categories = $Self->{ChangeObject}->ChangePossibleCIPGet(
        Type   => 'Category',
        UserID => $Self->{UserID},
    );
    $Param{'ChangeCategorySelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $Categories,
        Name       => 'CategoryIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{CategoryIDs},
    );

    # get possible Change Impacts
    my $Impacts = $Self->{ChangeObject}->ChangePossibleCIPGet(
        Type   => 'Impact',
        UserID => $Self->{UserID},
    );
    $Param{'ChangeImpactSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $Impacts,
        Name       => 'ImpactIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{ImpactIDs},
    );

    # get possible Change Priorities
    my $Priorities = $Self->{ChangeObject}->ChangePossibleCIPGet(
        Type   => 'Priority',
        UserID => $Self->{UserID},
    );
    $Param{'ChangePrioritySelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $Priorities,
        Name       => 'PriorityIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{PriorityIDs},
    );

    # get change states
    my $ChangeStates = $Self->{ChangeObject}->ChangePossibleStatesGet(
        UserID => $Self->{UserID},
    );
    $Param{'ChangeStateSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $ChangeStates,
        Name       => 'ChangeStateIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{ChangeStateIDs},
    );

    # get workorder agents
    $Param{'WorkOrderAgentIDSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => \%Users,
        Name       => 'WorkOrderAgentIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{WorkOrderAgentIDs},
    );

    # get workorder states
    my $WorkOrderStates = $Self->{WorkOrderObject}->WorkOrderPossibleStatesGet(
        UserID => 1,
    );
    $Param{'WorkOrderStateSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $WorkOrderStates,
        Name       => 'WorkOrderStateIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{WorkOrderStateIDs},
    );

    # get workorder types
    my $WorkOrderTypes = $Self->{WorkOrderObject}->WorkOrderTypeList(
        UserID => 1,
    );
    $Param{'WorkOrderTypeSelectionString'} = $Self->{LayoutObject}->BuildSelection(
        Data       => $WorkOrderTypes,
        Name       => 'WorkOrderTypeIDs',
        Multiple   => 1,
        Size       => 5,
        SelectedID => $Param{WorkOrderTypeIDs},
    );

    # set result output formats
    $Param{ResultFormStrg} = $Self->{LayoutObject}->BuildSelection(
        Data => {
            Normal => 'Normal',
            Print  => 'Print',
            CSV    => 'CSV',
        },
        Name       => 'ResultForm',
        SelectedID => $Param{ResultForm} || 'Normal',
    );

    my %Profiles = $Self->{SearchProfileObject}->SearchProfileList(
        Base      => 'ITSMChangeSearch',
        UserLogin => $Self->{UserLogin},
    );
    delete $Profiles{''};
    delete $Profiles{'last-search'};
    if ($EmptySearch) {
        $Profiles{''} = '-';
    }
    else {
        $Profiles{'last-search'} = '-';
    }
    $Param{ProfilesStrg} = $Self->{LayoutObject}->BuildSelection(
        Data       => \%Profiles,
        Name       => 'Profile',
        ID         => 'SearchProfile',
        SelectedID => $Profile,
    );

    # html search mask output
    $Self->{LayoutObject}->Block(
        Name => 'SearchAJAX',
        Data => { %Param, },    #%GetParam },
    );

    # number of minutes, days, weeks, months and years
    my %OneToFiftyNine = map { $_ => sprintf '%2s', $_ } ( 1 .. 59 );

    # time period that can be selected from the GUI
    my %TimePeriod = %{ $Self->{ConfigObject}->Get('ITSMWorkOrder::TimePeriod') };

    TIMETYPE:
    for my $TimeType (@TimeTypes) {
        my $Prefix = $TimeType->{Prefix};

        # show RequestedTime only when enabled in SysConfig
        if ( $Prefix eq 'Requested' && !$Self->{Config}->{RequestedTime} ) {
            next TIMETYPE;
        }

        my $Title             = $Self->{LayoutObject}->{LanguageObject}->Translate( $TimeType->{Title} );
        my %TimeSelectionData = (
            Prefix => $Prefix,
            Title  => $Title,
        );

        $TimeSelectionData{TimePoint} = $Self->{LayoutObject}->BuildSelection(
            Data       => \%OneToFiftyNine,
            Name       => $Prefix . 'TimePoint',
            SelectedID => $Param{ $Prefix . 'TimePoint' },
        );

        $TimeSelectionData{TimePointStart} = $Self->{LayoutObject}->BuildSelection(
            Data => {
                'Last'   => 'last',
                'Before' => 'before',
            },
            Name       => $Prefix . 'TimePointStart',
            SelectedID => $Param{ $Prefix . 'TimePointStart' } || 'Last',
        );

        $TimeSelectionData{TimePointFormat} = $Self->{LayoutObject}->BuildSelection(
            Data => {
                minute => 'minute(s)',
                hour   => 'hour(s)',
                day    => 'day(s)',
                week   => 'week(s)',
                month  => 'month(s)',
                year   => 'year(s)',
            },
            Name       => $Prefix . 'TimePointFormat',
            SelectedID => $Param{ $Prefix . 'TimePointFormat' },
        );

        $TimeSelectionData{TimeStart} = $Self->{LayoutObject}->BuildDateSelection(
            %Param,
            %TimePeriod,
            Prefix   => $Prefix . 'TimeStart',
            Format   => 'DateInputFormat',
            Validate => 1,
            DiffTime => -( ( 60 * 60 * 24 ) * 30 ),
        );

        $TimeSelectionData{TimeStop} = $Self->{LayoutObject}->BuildDateSelection(
            %Param,
            %TimePeriod,
            Prefix => $Prefix . 'TimeStop',
            Format => 'DateInputFormat',
        );

        # show time field
        $Self->{LayoutObject}->Block(
            Name => 'TimeSelection',
            Data => \%TimeSelectionData,
        );
    }

    # output Dynamic fields blocks
    # cycle trough the activated Dynamic Fields for this screen
    DYNAMICFIELD:
    for my $DynamicFieldConfig (
        @{ $Self->{DynamicFieldChange} },
        @{ $Self->{DynamicFieldWorkOrder} }
        )
    {
        next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);

        # get search field preferences
        my $SearchFieldPreferences = $Self->{BackendObject}->SearchFieldPreferences(
            DynamicFieldConfig => $DynamicFieldConfig,
        );

        next DYNAMICFIELD if !IsArrayRefWithData($SearchFieldPreferences);

        PREFERENCE:
        for my $Preference ( @{$SearchFieldPreferences} ) {

            # skip fields that HTML could not be retrieved
            next PREFERENCE if !IsHashRefWithData(
                $DynamicFieldHTML{ $DynamicFieldConfig->{Name} . $Preference->{Type} }
            );

            $Self->{LayoutObject}->Block(
                Name => 'DynamicField',
                Data => {
                    Label =>
                        $DynamicFieldHTML{ $DynamicFieldConfig->{Name} . $Preference->{Type} }
                        ->{Label},
                    Field =>
                        $DynamicFieldHTML{ $DynamicFieldConfig->{Name} . $Preference->{Type} }
                        ->{Field},
                },
            );
        }
    }

    # show attributes
    my %AlreadyShown;
    ITEM:
    for my $Item (@Attributes) {
        my $Key = $Item->{Key};
        next ITEM if !$Key;
        next ITEM if !defined $Param{$Key};
        next ITEM if $Param{$Key} eq '';
        next ITEM if $AlreadyShown{$Key};
        if ( ref $Param{$Key} eq 'ARRAY' && !@{ $Param{$Key} } ) {
            next ITEM;
        }
        $AlreadyShown{$Key} = 1;

        $Self->{LayoutObject}->Block(
            Name => 'SearchAJAXShow',
            Data => {
                Attribute => $Key,
            },
        );
    }

    # if no attribute is shown, show change number
    if ( !$Profile ) {

        $Self->{LayoutObject}->Block(
            Name => 'SearchAJAXShow',
            Data => {
                Attribute => 'ChangeNumber',
            },
        );
    }

    # build output
    my $Output = $Self->{LayoutObject}->Output(
        TemplateFile => 'AgentITSMChangeSearch',
        Data         => \%Param,
    );

    return $Output;
}

1;
