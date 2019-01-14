my $projPrincipal = "project: $pluginName";
my $ecscmProj = '$[/plugins/ECSCM/project]';

if ($promoteAction eq 'promote') {
    # Register our SCM type with ECSCM
    $batch->setProperty("/plugins/ECSCM/project/scm_types/@PLUGIN_KEY@", "ClearCase");
    
    # Give our project principal execute access to the ECSCM project
    my $xpath = $commander->getAclEntry("user", $projPrincipal,
                                        {projectName => $ecscmProj});
    if ($xpath->findvalue('//code') eq 'NoSuchAclEntry') {
        $batch->createAclEntry("user", $projPrincipal,
                               {projectName => $ecscmProj,
                                executePrivilege => "allow"});
    }
} elsif ($promoteAction eq 'demote') {
    # unregister with ECSCM
    $batch->deleteProperty("/plugins/ECSCM/project/scm_types/@PLUGIN_KEY@");
    
    # remove permissions
    my $xpath = $commander->getAclEntry("user", $projPrincipal,
                                        {projectName => $ecscmProj});
    if ($xpath->findvalue('//principalName') eq $projPrincipal) {
        $batch->deleteAclEntry("user", $projPrincipal,
                               {projectName => $ecscmProj});
    }
}

# Unregister current and past entries first.
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ECSCM-ClearCase - Checkout");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ECSCM-ClearCase - Preflight");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ClearCase - Checkout");
$batch->deleteProperty("/server/ec_customEditors/pickerStep/ClearCase - Preflight");

# Data that drives the create step picker registration for this plugin.
my %checkoutStep = (
    label       => "ClearCase - Checkout",
    procedure   => "CheckoutCode",
    description => "Checkout code from ClearCase.",
    category    => "Source Code Management"
);

my %Preflight = (
	label 		=> "ClearCase - Preflight",
	procedure 	=> "Preflight",
	description => "Checkout code from ClearCase during Preflight",
	category 	=> "Source Code Management"
);
@::createStepPickerSteps = (\%checkoutStep, \%Preflight);
