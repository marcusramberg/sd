package App::SD::Replica::Hiveminder;
use Moose;
extends 'Prophet::ForeignReplica';
use Params::Validate qw(:all);
use UNIVERSAL::require;
use URI;
use Memoize;
use Prophet::ChangeSet;
use File::Temp 'tempdir';

has hm => ( isa => 'Net::Jifty', is => 'rw');
has hm_url => ( isa => 'Str', is => 'rw');
has hm_username => ( isa => 'Str', is => 'rw');


use constant scheme => 'hm';


=head2 setup

Open a connection to the SVN source identified by C<$self->url>.

=cut

# XXX: this should be called from superclass, or better, have individual attributes have their own builders.

sub BUILD {
    my $self = shift;

    require Net::Jifty;
    my ($server) = $self->{url} =~ m/^hm:(.*?)$/
        or die "Can't parse Hiveminder server spec. Expected hm:http://hiveminder.com";
    $self->url($server);
    my $uri = URI->new($server);
    my ( $username, $password );
    if ( $uri->can('userinfo') && (my $auth = $uri->userinfo) ) {
        ( $username, $password ) = split /:/, $auth, 2;
        $uri->userinfo(undef);
    }
    $self->hm_url("$uri");

    ( $username, $password ) = $self->prompt_for_login( $uri, $username ) unless $password;

    $self->hm(
        Net::Jifty->new(
            site        => $self->hm_url,
            cookie_name => 'JIFTY_SID_HIVEMINDER',

            email    => $username,
            password => $password
        )
    );

    $self->hm_username($username);
}

=head2 uuid

Return the replica SVN repository's UUID

=cut

sub uuid {
    my $self = shift;
    return $self->uuid_for_url( join( '/', $self->hm_url, $self->hm_username ) );
}

sub traverse_changesets {
    my $self = shift;
    my %args = validate(
        @_,
        {   after    => 1,
            callback => 1,
        }
    );

    my $first_rev = ( $args{'after'} + 1 ) || 1;

    require App::SD::Replica::Hiveminder::PullEncoder;
    my $recoder = App::SD::Replica::Hiveminder::PullEncoder->new( { sync_source => $self } );
    for my $task ( @{ $self->find_matching_tasks } ) {
        $args{callback}->($_)
            for @{
            $recoder->run(
                task => $task,
                transactions =>
                    $self->find_matching_transactions( task => $task->{id}, starting_transaction => $first_rev )
            )
            };
    }
}

sub find_matching_tasks {
    my $self  = shift;
    my $tasks = $self->hm->act(
        'TaskSearch',
        owner        => 'me',
        group        => 0,
        requestor    => 'me',
        not_complete => 1,

    )->{content}->{tasks};
    return $tasks;
}

sub prophet_has_seen_transaction {
    goto \&App::SD::Replica::RT::prophet_has_seen_transaction;
}

sub record_pushed_transaction {
    goto \&App::SD::Replica::RT::record_pushed_transaction;
}

sub record_pushed_transactions {

    # don't need this for hm
}

sub _txn_storage {
    goto \&App::SD::Replica::RT::_txn_storage;
}

# hiveminder transaction ~= prophet changeset
# hiveminder taskhistory ~= prophet change
# hiveminder taskemail ~= prophet change
sub find_matching_transactions {
    my $self = shift;
    my %args = validate( @_, { task => 1, starting_transaction => 1 } );

    my $txns = $self->hm->search( 'TaskTransaction', task_id => $args{task} ) || [];
    my @matched;
    foreach my $txn (@$txns) {
        next if $txn->{'id'} < $args{'starting_transaction'};    # Skip things we've pushed

        next if $self->prophet_has_seen_transaction( $txn->{'id'} );

        $txn->{history_entries} = $self->hm->search( 'TaskHistory', transaction_id => $txn->{'id'} );
        $txn->{email_entries}   = $self->hm->search( 'TaskEmail',   transaction_id => $txn->{'id'} );
        push @matched, $txn;
    }
    return \@matched;

}

sub _integrate_change {
    my $self = shift;
    my ( $change, $changeset ) = validate_pos(
        @_,
        { isa => 'Prophet::Change' },
        { isa => 'Prophet::ChangeSet' }
    );

    require App::SD::Replica::Hiveminder::PushEncoder;
    my $recoder = App::SD::Replica::Hiveminder::PushEncoder->new( { sync_source => $self } );
    $recoder->integrate_change($change,$changeset);
}



{

    # XXXXXXXX
    # XXXXXXXXX
    # XXX todo code in this block cargo culted from the RT Replica type

    sub remote_id_for_uuid {
        my ( $self, $uuid_for_remote_id ) = @_;

        # XXX: should not access CLI handle
        my $ticket = Prophet::Record->new( handle => Prophet::CLI->new->handle, type => 'ticket' );
        $ticket->load( uuid => $uuid_for_remote_id );
        return $ticket->prop( $self->uuid . '-id' );
    }

    sub uuid_for_remote_id {
        my ( $self, $id ) = @_;
        return $self->_lookup_remote_id($id) || $self->uuid_for_url( $self->hm_url . "/task/$id" );
    }

    sub _lookup_remote_id {
        my $self = shift;
        my ($id) = validate_pos( @_, 1 );

        return $self->_remote_id_storage( $self->uuid_for_url( $self->hm_url . "/task/$id" ) );
    }

    sub _set_remote_id {
        my $self = shift;
        my %args = validate(
            @_,
            {   uuid      => 1,
                remote_id => 1
            }
        );
        return $self->_remote_id_storage( $self->uuid_for_url( $self->hm_url . "/task/" . $args{'remote_id'} ),
            $args{uuid} );
    }

}

sub record_pushed_ticket {
    my $self = shift;
    my %args = validate(
        @_,
        {   uuid      => 1,
            remote_id => 1
        }
    );
    $self->_set_remote_id(%args);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
