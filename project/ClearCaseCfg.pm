####################################################################
#
# ECSCM::ClearCase::Cfg: Object definition of CC  configuration.
#
####################################################################
package ECSCM::ClearCase::Cfg;
@ISA = (ECSCM::Base::Cfg);
if (!defined ECSCM::Base::Cfg) {
    require ECSCM::Base::Cfg;
}


####################################################################
# Object constructor for ECSCM::ClearCase::Cfg
#
# Inputs
#   cmdr  = a previously initialized ElectricCommander handle
#   name  = a name for this configuration
####################################################################
sub new {
    my $class = shift;

    my $cmdr = shift;
    my $name = shift;

    my($self) = ECSCM::Base::Cfg->new($cmdr,"$name");
    bless ($self, $class);
    return $self;
}


## all configuration is done with cleartool
## no command line options for user/pass/server needed
1;
