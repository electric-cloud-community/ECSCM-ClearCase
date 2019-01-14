####################################################################################
# Check Params
#
#
####################################################################################
my $useRegion = "$[useRegion]";
my $stgloc = "$[stgloc]";
my $region = "$[region]";

if (($useRegion eq "1") && ($region eq ""))  {
   print "Warning: If you marked the option 'use region' you must provide a region. Please check the parameters and run the procedure again.";
} 
