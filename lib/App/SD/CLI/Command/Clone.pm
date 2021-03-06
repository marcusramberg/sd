package App::SD::CLI::Command::Clone;
use Any::Moose;
extends 'Prophet::CLI::Command::Clone';
with 'App::SD::CLI::NewReplicaCommand';

sub ARG_TRANSLATIONS {
    shift->SUPER::ARG_TRANSLATIONS(),
    n => 'non-interactive',
};

sub usage_msg {
    my $self = shift;
    my $cmd = $self->cli->get_script_name;

    return <<"END_USAGE";
usage: ${cmd}clone --from <url> [--non-interactive]

Options:
    -n | --non-interactive - Don't prompt to specify email address for new
                             database
END_USAGE
}

override run => sub {
    my $self = shift;

    # clone dies if the target replica already exists, so no need
    # to worry about not running the wizard if the clone doesn't run
    $self->SUPER::run();

    Prophet::CLI->end_pager();

    $self->new_replica_wizard( edit_settings => 0 );
};

__PACKAGE__->meta->make_immutable;
no Any::Moose;

1;

