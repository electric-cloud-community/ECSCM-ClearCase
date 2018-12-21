####################################################################
#
# ECSCM::ClearCase::Driver  Object to represent interactions with 
#        clearcase.
####################################################################
package ECSCM::ClearCase::Driver;
@ISA = (ECSCM::Base::Driver);
use ElectricCommander;
use Cwd;
use Time::Local;
use File::Spec;
use File::Copy::Recursive qw(fcopy rcopy dircopy fmove rmove dirmove);
use HTTP::Date(qw {str2time time2str time2iso time2isoz});
use Getopt::Long;
use File::Find;


# change logs for each vob object will be stored here
my $changeLogs_hash; # hash reference

# the argument to "cleartool lshistory -since"
my $changeLogs_since = "";

if (!defined ECSCM::Base::Driver) {
    require ECSCM::Base::Driver;
}

if (!defined ECSCM::ClearCase::Cfg) {
    require ECSCM::ClearCase::Cfg;
}

if (defined $ENV{COMMANDER_JOBID}) {
    $::jobId = $::ENV{COMMANDER_JOBID};
} else {
    $::jobId = time();
}


####################################################################
# Object constructor for ECSCM::ClearCase::Driver
#
# Inputs
#    cmdr          previously initialized ElectricCommander handle
#    name          name of this configuration
#                 
####################################################################
sub new {
    my $this = shift;
    my $class = ref($this) || $this;

    my $cmdr = shift;
    my $name = shift;
    my $sys;

    my $cfg = new ECSCM::ClearCase::Cfg($cmdr, "$name");
    if ("$name" ne "") {
        $sys = $cfg->getSCMPluginName();
        if ("$sys" ne "ECSCM-ClearCase") { die "SCM config $name is not type ECSCM-ClearCase"; }
    }
    my ($self) = new ECSCM::Base::Driver($cmdr,$cfg);
    
    my $pluginKey = $sys;
    my $xpath = $cmdr->getPlugin($pluginKey);
    my $pluginName = $xpath->findvalue('//pluginVersion')->value;
    print "\nUsing plugin $pluginKey version $pluginName\n";
    
    bless ($self, $class);
    $::self = $self;
    return $self;
}

####################################################################
# isImplemented
####################################################################
sub isImplemented {
    my ($self, $method) = @_;
    
    if ($method eq 'getSCMTag' || 
        $method eq 'checkoutCode' || 
        $method eq 'apf_driver' || 
        $method eq 'cpf_driver') {
        return 1;
    } else {
        return 0;
    }
}

####################################################################
# get scm tag for sentry (continuous integration)
####################################################################

####################################################################
# getSCMTag
# 
# Get the latest changelist on this branch/client
#
# Args:
# Return: 
#    changeTimeString   - a string representing the last change sequence
#    changeTimeStamp    - a time stamp representing the time of last change
#         
####################################################################
sub getSCMTag
{
    my ($self, $opts) = @_;

    my $clearCaseView = $opts->{ClearCaseView};
    my $clearCasePath = $opts->{ClearCasePath};
    my $clearCaseBranch = $opts->{ClearCaseBranch};
    my $previousTimeString = $opts->{LASTATTEMPTED};
    
    # Start the view
    my $command = "cleartool startview $clearCaseView ";
    my $response = $self->RunCommand($command, 
                                     {LogCommand =>1, LogResult => 1});

    # Set options on the query
    $ENV{CCASE_ISO_DATE_FMT} = 1;
    my $branchOption = (length $clearCaseBranch) ? " -branch $clearCaseBranch" : "";
    my $bGetLast = ($previousTimeString eq "");
    my $scopeOption = ($bGetLast) ? " -last -all" : " -recurse";

    # Add one second to the previous time, so that we don't retrieve the
    # previous event.  This could lead to some race conditions, but should
    # be OK as long as there is always a quiet period enforced.
    my $sinceOption = "";
    if ($previousTimeString ne "") {
        my $timeStamp = str2time($previousTimeString);
        $timeStamp++;

        # Returns a string of the form - Sun, 25 Nov 2007 01:28:56 GMT
        # Convert it to a form that ClearCase accepts - 25-Nov-07.01:28:56UTC
        #  NOTE - this works in the US, but has not been tested in other locales
        #         (not sure how ClearCase handles input dates for locales)
        my $sinceTime = time2str($timeStamp);
        $sinceTime =~ s/^[^\d]*([\d]+) ([\D]+) ([\d]+) ([:\d]+) GMT/$1-$2-$3.$4UTC/;
        $sinceOption = " -since $sinceTime";
    }

    # Query ClearCase for changes
    $command = "cleartool lshistory" .
               "$branchOption".
               "$scopeOption".
               "$sinceOption".
               " -nco".
               ' -fmt "     Object: %n\n' .
                      '       Type: %m\n' .
                      '  Operation: %o\n' .
                      '      Event: %e\n' .
                      '       User: %u\n' .
                      '       Date: %d\n' .
                      '\n"' .
               " $clearCasePath" ;
    $response = $self->RunCommand($command, {LogCommand =>1, LogResult => 1});

    #  Search the blocks looking for the time of the newest
    #  "qualifying" operation, that is, an event that should
    #  trigger a build
    my $changeTimeStamp = 0;
    my $changeTimeString =  "";
    my $qualifyingOperations = "checkin import mkelem rmelem rmver";
    foreach my $block (split (/^\s*$/m, $response)) {
        foreach my $line (split (/\n/, $block)) {
            if  ($line =~ /^\s*Operation: (.*)/)
            {
                my $bQualifyingOperation = (index($qualifyingOperations, $1) >= 0);
                if (!$bQualifyingOperation  &&  !$bGetLast) {
                    # skip to the next block without processing its date field
                    last;
                }
            }
            if  ($line =~ /^\s*Date: (.*)/)
            {
                # save the newest qualifying time
                # NOTE - It appears that ClearCase returns events in reverse
                #        time order, but it is not documented, so this
                #        continues looking through all returned events

                my $time = str2time($1);
                if ($time > $changeTimeStamp) {

                    $changeTimeStamp = $time;
                    $changeTimeString =  $1;
                }
            }
        }
    }
    # Return the time string and the time stamp
    return ($changeTimeString, $changeTimeStamp);
}

####################################################################
# code checkout for ecsnapshot
####################################################################

#------------------------------------------------------------------------------
# checkoutCode
#
#       Create the basic source snapshot 
#------------------------------------------------------------------------------
sub checkoutCode 
{
    my ($self, $opts) = @_;
    
    if (!defined $opts->{dest}) {
        warn "dest argument required in checkoutCode";
        return;
    }

    $opts->{dest} = File::Spec->rel2abs($opts->{dest});
    
    my $command = "cleartool mkview";
    if ($opts->{useRegion} eq "1")
    {
        if ($opts->{region} ne "") {
        $command .= " -tag commander-dynamic-view-tag-$::jobId "
                 . "-region \"$opts->{region}\" ";
        
        $command .= "-stgloc \"$opts->{stgloc}\" " if ($opts->{stgloc} ne "");
        
        $command .= "\"$opts->{dest}\"";
        } else {
          warn "region param cannot be null";
          return;
        }                 
    } else {
        if ($opts->{stgloc} ne ""){
            $command .= " -snapshot -stgloc \"$opts->{stgloc}\" "
                . "-tag commander-snapshot-$::jobId \"$opts->{dest}\"";
        } else { 
            $command .= " -snapshot "
                . "-tag commander-snapshot-$::jobId \"$opts->{dest}\"";
        }
    }
        
    my $res = $self->RunCommand($command, {LogCommand => 1});
    print "$command \n";
    
    if (!defined $res) { $res = ""; }
    
    if ($opts->{useRegion} eq "1") {
       print "Command: \n$command\nHad the following output:\n $res\n\n";
    } else{
        if ($res =~m/Created snapshot view directory/ ) {
            print "Command: \n$command\nHad the following output:\n $res\n\n";
        } else {
            return;
        }
    }

    my $origDir = getcwd();

    chdir($opts->{dest}) || $self->error("could not change dir to $opts->{dest}");

    $command = "cleartool setcs \"$opts->{ConfigSpecFileName}\"";
        
    my $out = $self->RunCommand($command, {LogCommand => 1});
    if (!defined $out) { $out = ""; }

    if (!$self->isTestMode() && $out !~ m/Log has been written to \".*\".\n/) {
        $self->error("Command \"$command\" failed with errors: $out\n");
    }
    
    # get the current time and convert it to a form clearcase accepts.
    # see note on this in getSCMTag
    my $currTime = time();
    my $now = time2str($currTime);
    $now =~ s/^[^\d]*([\d]+) ([\D]+) ([\d]+) ([:\d]+) GMT/$1-$2-$3.$4UTC/;

    $opts->{ConfigSpecFileName} = File::Spec->rel2abs($opts->{ConfigSpecFileName});

    my $scmKey = $self->getKeyFromConfigSpec($opts->{ConfigSpecFileName});

    $changeLogs_since = "";
    $changeLogs_since = $self->getStartForChangeLog($scmKey);

    if ($changeLogs_since eq "") {
	$changeLogs_since = $now;
    }

    my @dirs = ($opts->{dest});
    my $changeLog = getChangeLog(\@dirs);

    $self->setPropertiesOnJob($scmKey, $now, $changeLog);

    chdir($origDir);
   
    my $view_name = '';
    if ($opts->{useRegion} eq "1") {
        $view_name = "commander-dynamic-view-tag-$::jobId";
    } else {
        $view_name = "commander-snapshot-$::jobId";
    }
    $command = "cleartool rmview -force -tag $view_name"; 
    
    if ($opts->{deleteView}) {
        #remove it               
        $self->RunCommand($command, {LogCommand => 1});
    } else {
        print "The current view was not deleted, if you want to remove it later please use the 'DeleteView' method."
             ."\nThe view name is: $view_name\n";
        print "You can also run: $command from the command line\n";     
    }
        
    return 1;   
}

#------------------------------------------------------------------------------
# deleteView
#
#       Delete the specified view 
#------------------------------------------------------------------------------
sub deleteView
{
    my ($self, $opts) = @_;
            
    my $command = "cleartool rmview -force -tag $opts->{viewName}";        
    $self->RunCommand($command, {LogCommand => 1, LogResult => 1});    
}

####################################################################
# getKeyFromConfigSpec
#
# Side Effects:
#
# Arguments:
#   configSpec  - a path to a clearcase config spec
#
# Returns:
#   "ClearCase" prepended to the path to a config spec with all / replaced by __slash__
####################################################################
sub getKeyFromConfigSpec
{
    my ($self, $configSpec) = @_;
    $configSpec =~ s/\//__slash__/g;
    return "ClearCase-$configSpec";
}

####################################################################
# getConfigSpecFromKey
#
# Side Effects:
#   
# Arguments:
#   key  -              a key in a property sheet
#
# Returns:
#   A path to a clearcase config spec
####################################################################
sub getConfigSpecFromKey
{
    my ($self, $key) = @_;
    $key =~ s/^ClearCase-//;
    $key =~ s/__slash__/\//g;
    return $key;
}

####################################################################
# iflshistory
#
#   Executes "cleartool lshistory" on the current directory.
#
# Side Effects:
#   If the cleartool command succeeds, adds an entry to a hash
#   where the key is the current directory and the value
#   is the output of the command.  
# 
# Arguments:
#
# Returns:
#   True if the command succeeded.  False otherwise.
#
####################################################################
sub iflshistory()
{
    my $result = "";
    my $command = "cleartool lshistory -r -nco -since $changeLogs_since";

    eval {
        $result = `$command 2>&1`;
    };

    if ($?) {
        # should we check for specific error:
        # cleartool: Error: Not an object in a vob: ".".
                
        return 0;
    } else {
        my $dir = getcwd();
        $changeLogs_hash->{$dir} = $result;
        return 1;
    }
}

####################################################################
# preprocess
#
#   subroutine used by find method in getChangeLog.  Decides whether
#   to continue processing the current directory by calling
#   iflshistory.
#
# Side Effects:
#   
# Arguments:
#
# Returns:
#   Returns all immediate subdirectories of the current directory
#   or nothing.
####################################################################
sub preprocess {

    if (iflshistory()) {
        return;        
    } else {
        return @_;        
    }
}

####################################################################
# wanted
#
#   subroutine used by find in getChangeLog.  Decides whether
#   to continue processing the current directory by calling
#   iflshistory.
#
# Side Effects:
#   
# Arguments:
#
# Returns:
#
####################################################################
sub wanted {

    if (iflshistory()) {
        return;
    }
}


####################################################################
# getChangeLog
#
# Side Effects:
#   
# Arguments:
#   dir -        an array of directories to process
#
# Returns:
#   A concatenation of all change logs or "".
#
####################################################################
sub getChangeLog
{
    my($dirs) = @_;

    my $log = "";

    print "preprocess: ", preprocess, "\n";
    print "wanted: ", wanted, "\n";
    
    find( {
        preprocess => \&preprocess,
        wanted => \&wanted,
    }, @$dirs);

    foreach my $key (keys % $changeLogs_hash) {
        $log .= $changeLogs_hash->{$key};
    }
    return $log;
}

####################################################################
# agent preflight drivers
####################################################################


#------------------------------------------------------------------------------
# getScmInfo
#
#       If the client script passed some SCM-specific information, then it is
#       collected here.
#------------------------------------------------------------------------------
sub apf_getScmInfo {
    my ($self, $opts) = @_;

    if ($self->isWindows() && -f "ecpreflight_data/winCSpec") {
        $opts->{ConfigSpecType} = "winCSpec";
     } elsif (!$self->isWindows() && -f "ecpreflight_data/unixCSpec") {
        $opts->{ConfigSpecType} = "unixCSpec";
    } else {
        $opts->{ConfigSpecType} = "defaultCSpec";
    }

    my $origDir = getcwd();
    $opts->{ConfigSpecFileName} = "$origDir/ecpreflight_data/$opts->{ConfigSpecType}";
    print("Using Clearcase config spec $opts->{ConfigSpecFileName}:\n"
            . $self->pf_readFile("$opts->{ConfigSpecFileName}"));

    # parse the scmInfo file
    my @lines = split(/\n/, $self->pf_readFile("ecpreflight_data/scmInfo"));
    foreach (@lines) {
        chomp($_);
        if( $_ ne "" ) {
            my @elements = split /=/, $_;
            if ($elements[0] eq "clientType") {
                $opts->{ClientType} = $elements[1];
                print "Client Type = $opts->{ClientType}\n";

            } elsif ($elements[0] eq "unixRelativePath") {
                $opts->{UnixRelativePath}=$elements[1];
                print "Unix Target Dir = $opts->{UnixRelativePath}\n";

            } elsif ($elements[0] eq "winRelativePath") {
                $opts->{WinRelativePath} = $elements[1];
                print "Window Target Dir = $opts->{WinRelativePath}\n";

            }
        }
    }
}

#------------------------------------------------------------------------------
# createSnapshot
#
#       Create the basic source snapshot before overlaying the deltas passed
#       from the client.
#------------------------------------------------------------------------------
sub apf_createSnapshot 
{
    my ($self,$opts) = @_;

    my ($result) = $self->checkoutCode($opts);
    print "checked out $result\n";
}

#------------------------------------------------------------------------------
# exitDriver
#
#       Exit handler to clean up the temporary cleartool view if it has already
#       been created.
#------------------------------------------------------------------------------
sub exitDriver
{
    print "In ExitDriver\n";
}



#------------------------------------------------------------------------------
# updatePaths
#
# Updates the paths in files in ecpreflight_data as well as the file structure
# of ecpreflight_files if we are executing on platform for which the appropriate
# *RelativePath has been set.  This functionality is necessary when the client
# and server are on different platforms and there exists a difference between
# where sources are extracted for the clearcase project being manipulated.
# For example, the same clearcase project can be represented by different
# clearcase config specs on different platforms, which may result in sources
# being extracted to \proj1 on windows, but /vob/proj1 on unix, depending on the
# load rules in the config spec.
#------------------------------------------------------------------------------

sub apf_updatePaths 
{
    my ($self, $opts) = @_;
    my $dir = "";
    
    #
    # determine whether we need to do path adjustment
    #
    if ($self->isWindows() && defined($opts->{WinRelativePath}) && $opts->{WinRelativePath} ne "") {
        $dir = $opts->{WinRelativePath};        
    } elsif (!$self->isWindows() && defined($opts->{UnixRelativePath}) && $opts->{UnixRelativePath} ne "") {
        $dir = $opts->{UnixRelativePath};        
    } else {
        return;
    }

    #
    # deal with files in ecpreflight_data
    #
    $self->apf_updatePathsHelper($dir, "ecpreflight_data/directories", "ecpreflight_data/directories.orig");
    $self->apf_updatePathsHelper($dir, "ecpreflight_data/deltas", "ecpreflight_data/deltas.orig");
    $self->apf_updatePathsHelper($dir, "ecpreflight_data/deletes", "ecpreflight_data/deletes.orig");

    #
    # deal with ecpreflight_files directory
    #

    # back up the original ecpreflight_files directory
    my $storageDir = $opts->{delta};    
    my $origStorageDir = "$storageDir.orig";

    if (File::Copy::move($storageDir, $origStorageDir)) {
        print "Moving $storageDir to $origStorageDir\n"; 
    } else {
        $self->error("Failed moving $storageDir to $origStorageDir, exiting.\n");
    }

    mkdir($storageDir);

    if (! opendir(DIR, $origStorageDir) ) {
        error("Open $origStorageDir failed with: $!, exiting");
    } 

    # copy all directories from the back up directory to an adjusted path in
    # in ecpreflight_files
    while (my $elem = readdir(DIR)) {

        next unless ("$elem" !~ m/^\.+$/);

        my $source = "$origStorageDir/$elem";
        my $dest = "$storageDir/$dir/$elem";
        if (rcopy($source, $dest)) {
            print "Copied $source to $dest\n"; 
        } else {
            $self->error("Failed copying $source to $dest\n");
        }
    }
    closedir(DIR);
}

#------------------------------------------------------------------------------
# updatePathsHelper
#
# Prepends a relative directory to the paths in a file.
#
# Arguments:
#       dir - the relative directory to prepend
#       file - the file to manipulate
#       origfile - the location of the backup for the file
#------------------------------------------------------------------------------

sub apf_updatePathsHelper
{
    my ($self, $dir, $file, $origfile) = @_;

    if (-e $file && -s "$file" > 0) {
        if (File::Copy::move($file, $origfile)) {
            print "Moved $file to $origfile\n"; 
        } else {
            $self->error("Failed moving $file to $origfile, exiting.");
        }

        if (! open(ORIG_FILE, $origfile) ) {
            $self->error("Open $origfile failed with: $!, exiting");
        }
        
        my @origfileContents = <ORIG_FILE>;
        close(ORIG_FILE);
        
        if (! open(FILE, ">", $file) ) {
            $self->error("Open $file failed with: $!, exiting");
        }
        
        my $tmpline = "";
        foreach my $line (@origfileContents) {
            if( $line ne "" ) {
                $tmpline = "$dir/$line";
                print(FILE $tmpline);
            }
        }
        close FILE;
    }
}

#------------------------------------------------------------------------------
# driver
#
#       Main program for the application.
#------------------------------------------------------------------------------

sub apf_driver()
{
    my ($self, $opts) = @_;
    
    print "Running agent preflight driver.\n";
    if ($opts->{test}) { $self->setTestMode(1); }
    $opts->{delta} = "ecpreflight_files";    
    
    $self->apf_downloadFiles($opts);
    $self->apf_transmitTargetInfo($opts);
    $self->apf_getScmInfo($opts);
    $self->apf_createSnapshot($opts);
    $self->apf_updatePaths($opts);
    $self->apf_deleteFiles($opts);
    $self->apf_createDirectories($opts);
    $self->apf_overlayDeltas($opts);
}

####################################################################
# client preflight drivers
####################################################################

#------------------------------------------------------------------------------
# ct
#
#       Runs a cleartool command.  For testing, the requests and responses will
#       be pre-arranged.
#------------------------------------------------------------------------------
sub cpf_ct{
    my ($self,$opts,$command, $options) = @_;
    $self->cpf_debug("Running Clearcase command \"$command\"");
    if ($opts->{opt_Testing}) {
        my $request = uc("ct_$command");
        $request =~ s/[^\w]//g;
        if (defined($ENV{$request})) {
            return $ENV{$request};
        } else {
            $self->error("Pre-arranged command output not found in ENV");
        }
    } else {
        return $self->RunCommand("cleartool $command", $options);
    }
}

#------------------------------------------------------------------------------
# copyDeltas
#
#       Finds all new and modified files and either copies them directly to
#       the job's workspace or transfers them via the server using putFiles.
#       The job is kicked off once the sources are ready to upload.
#       Should collect delta information for each VOB
#------------------------------------------------------------------------------
sub cpf_copyDeltas()
{
    my ($self,$opts) = @_;
    
    
    $self->cpf_display("Collecting delta information");
    
    
    # Create a file with specific SCM information needed on the agent-side
    # to create the source snapshot.

    my $infoFile = File::Spec->catfile($opts->{opt_LogDir}, "ecpreflight_configSpec");
    $self->pf_saveDataToFile($infoFile, $self->cpf_ct($opts,"catcs"));
    my $uploadFile = File::Spec->catfile("ecpreflight_data","defaultCSpec");
    # replace all \ with /
    $infoFile =~ s/\\/\//g;
    $uploadFile =~ s/\\/\//g;
    $self->cpf_debug("Adding config spec file \"$infoFile\" to copy to \"$uploadFile\" ");
    $opts->{rt_FilesToUpload}{$infoFile} = $uploadFile;

    if (defined($opts->{scm_unixCSpecPath}) && $opts->{scm_unixCSpecPath} ne "") {
        $infoFile = File::Spec->catfile($opts->{opt_LogDir}, "ecpreflight_unixCSpec");
        my $cspec = $self->pf_readFile($opts->{scm_unixCSpecPath});
        $self->pf_saveDataToFile($infoFile, $cspec);
        $uploadFile = File::Spec->catfile("ecpreflight_data", "unixCSpec");
        # replace all \ with /
        $infoFile =~ s/\\/\//g;
        $uploadFile =~ s/\\/\//g;
        $self->cpf_debug("Adding config spec file \"$infoFile\" to copy to \"$uploadFile\" ");
        $opts->{rt_FilesToUpload}{$infoFile} = $uploadFile;
    }

    if (defined($opts->{scm_winCSpecPath}) && $opts->{scm_winCSpecPath} ne "") {
        $infoFile = File::Spec->catfile($opts->{opt_LogDir}, "ecpreflight_winCSpec");
        my $cspec = $self->pf_readFile($opts->{scm_winCSpecPath});
        $self->pf_saveDataToFile($infoFile, $cspec);
        $uploadFile = File::Spec->catfile("ecpreflight_data", "winCSpec");
        # replace all \ with /
        $infoFile =~ s/\\/\//g;
        $uploadFile =~ s/\\/\//g;
        $self->cpf_debug("Adding config spec file \"$infoFile\" to copy to \"$uploadFile\" ");
        $opts->{rt_FilesToUpload}{$infoFile} = $uploadFile;
    }

    my %scmInfo = ();
    my $type = "unix";
    if ($self->isWindows()) {
        $type = "win";
    }

    $scmInfo{"clientType"} = $type;

    if (defined($opts->{scm_unixRelativePath}) && $opts->{scm_unixRelativePath} ne "") {
        $scmInfo{"unixRelativePath"} = $opts->{scm_unixRelativePath};
    }

    if (defined($opts->{scm_winRelativePath}) && $opts->{scm_winRelativePath} ne "") {
        $scmInfo{"winRelativePath"} = $opts->{scm_winRelativePath};
    }

    my $str = "";

    while ( my ($key, $value) = each(%scmInfo) ) {
        $str .= "$key=$value\n";
    }

    $self->cpf_saveScmInfo($opts,$str);
    $self->cpf_findTargetDirectory($opts);
    $self->cpf_createManifestFiles($opts);

    # Collect a list of checked-out files/directories.  Add these files and
    # directories to the delta lists.
   
    my @vob_root_directories;
    if (defined $opts->{vob_directories}) {
        @vob_root_directories = split("\n",$opts->{vob_directories});
    } else {
        @vob_root_directories = (".");
    }
        
    
    my @directories = ();
    my $history;
    my $numDeltas = 0;
    
    foreach (@vob_root_directories) {
       
 	   my $orig_dir = getcwd();
       if ($_ ne ".") {
            chdir($_);            
       }
     
        my $output = $self->cpf_ct($opts,"lscheckout -cview -recurse -short");
        $opts->{opt_openedFiles} = $output;
          
       
        foreach my $element (split(/\n/, $output)) {
            if ($element eq " ") {
                next;
            }
            
            $numDeltas ++;
            my $directory = "";
            my $fullPathToElement = "";
            
            my $temp_element = $element;
            if ($_ ne ".") { 
             $temp_element = substr($element, 1);
             $temp_element = $_ . $temp_element;
            }
            
            if (-d $element) {
                $directory = "-directory ";
                $fullPathToElement = File::Spec->catdir($opts->{scm_path}, $temp_element);
            } else {
                $fullPathToElement = File::Spec->catfile($opts->{scm_path}, $temp_element);
            }

            $history = $self->cpf_ct($opts,"lshistory -short -last 1 $directory\"$element\"");
            if ($history !~ m/.*CHECKEDOUT\n/) {
                my $msg = "Element \"$fullPathToElement\" is out of sync "
                        . "with the head";
                if ($opts->{scm_autoCommit}) {
                    $self->cpf_error($msg);
                } else {
                    $self->cpf_display($msg);
                }
            }
            
            # replace all \ with /
            $temp_element =~ s/\\/\//g;
            $fullPathToElement =~ s/\\/\//g;

            $self->cpf_debug("  element: $element");
            $self->cpf_debug("  full path to element: $fullPathToElement");

            if (-f $element) {
                $self->cpf_addDelta($opts,$fullPathToElement, $temp_element);
            } elsif (-d $element) {               
                $self->cpf_addDirectory($temp_element);
                push(@directories, $temp_element);
            } else {
                $self->cpf_error("Checked out element \"$temp_element\" does not exist");
            }
        }   

        chdir($orig_dir);        
    }
    
    # Check the difference between each checked out directory and its
    # predecessor, and upload information for added, deleted, and renamed
    # elements.

    foreach my $directory (@directories) {
        my $diff = $self->cpf_ct($opts,"diff -pred \"$directory\"", {dieOnError => 0});
        $opts->{opt_openedFiles} .= $diff;
        my $add = 0;
        my $rename = 0;
        my $delete = 0;
        foreach my $element (split(/\n/, $diff)) {
            my $addTarget = "";
            my $deleteTarget = "";
            if ($add) {
                $element =~ m/[ ]*-\| (.*)[ ]*--.*/;
                $addTarget = File::Spec->catfile($directory, $1);
            } elsif ($rename) {
                $element =~ m/(.*)[ ]*--.*\| (.*)[ ]*--.*/;
                $deleteTarget = File::Spec->catfile($directory, $1);
                $addTarget = File::Spec->catfile($directory, $2);
            } elsif ($delete) {
                $element =~ m/(.*)[ ]*--.*/;
                $deleteTarget = File::Spec->catfile($directory, $1);
            } elsif ($element =~ m/[-]*\[ renamed.*/) {
                $rename = 1;
                next;
            } elsif ($element =~ m/[-]*\|[-]*\[ added.*/) {
                $add = 1;
                next;
            } elsif ($element =~ m/[-]\[ removed.*/) {
                $delete = 1;
                next;
            }

            # replace all \ with /
            $addTarget =~ s/\\/\//g;
            $deleteTarget =~ s/\\/\//g;

            if ($addTarget ne "") {
                $addTarget =~ s/\s+$//;
  
                if ( -d $addTarget) {                    
                    $self->cpf_addDirectory($addTarget);
                } else {
                    my $tmpFile = File::Spec->catfile($opts->{scm_path}, $addTarget);
                    # replace all \ with /
                    $tmpFile =~ s/\\/\//g;
                    $addTarget =~ s/\\/\//g;
                    $self->cpf_addDelta($opts,$tmpFile, $addTarget);
                }
            }
            if ($deleteTarget ne "") {
                $deleteTarget =~ s/\s+$//;             
                if ( -d $deleteTarget) {
                    $deleteTarget = $1;
                }
                $self->addDelete($deleteTarget);
            }
            $add = 0;
            $rename = 0;
            $delete = 0;
        }
    }

    $self->cpf_closeManifestFiles($opts);
    $self->cpf_uploadFiles($opts);

    # If there aren't any modifications, warn the user, and turn off auto-
    # commit if it was turned on.

    if ($numDeltas == 0) {
        my $warning = "No files are currently checked out";
        if ($opts->{scm_autoCommit}) {
            $warning .= ".  Auto-commit has been turned off for this build";
            $opts->{scm_autoCommit} = 0;
        }
        $self->cpf_display($warning);
    }
    
    if (defined $origDir) {
      chdir ($origDir);
    }
}

#------------------------------------------------------------------------------
# autoCommit
#
#       Automatically commit changes in the user's client.  Error out if:
#       - A check-in has occurred since the preflight was started, and the
#         policy is set to die on any check-in.
#       - A check-in has occurred and opened files are out of sync with the
#         head of the branch.
#       - A check-in has occurred and non-opened files are out of sync with
#         the head of the branch, and the policy is set to die on any changes
#         within the client workspace.
#------------------------------------------------------------------------------
sub cpf_autoCommit
{
    my ($self,$opts) = @_;
    # Make sure none of the files have been touched since the build started.

    $self->cpf_checkTimestamps($opts);
    
    my @vob_root_directories;
    my $directories = $opts->{vob_directories};
    if (defined $opts->{vob_directories}) {
        @vob_root_directories = split("\n",$opts->{vob_directories});
    } else {
        @vob_root_directories = (".");
    }            
    foreach (@vob_root_directories) {
       my $orig_dir = getcwd();
       if ($_ ne ".") {
            chdir($_);            
        }
           
        # Check the list of checked out elements.  If there have been any changes,
        # error out.
        my @directories = ();    
        my $output = $self->cpf_ct($opts,"lscheckout -cview -recurse -short");
        my $elementsToCommit = $output;
        foreach my $element (split(/\n/, $output)) {
            if (-d $element) {
                push(@directories, $element);
            }
        }
        foreach my $directory (@directories) {
            # replace all \ with /
            $directory =~ s/\\/\//g;
            my $diff = $self->cpf_ct($opts,"diff -pred \"$directory\"", {dieOnError => 0});
            $output .= $diff;
        }

        if ($output ne $opts->{opt_openedFiles}) {
            $self->cpf_error("Files have been added and/or removed from the selected "
                    . "changelists since the preflight build was launched");
        } 

        foreach my $element (split(/\n/, $elementsToCommit)) {
            my $directory = "";
            
            my $temp_element = $element;
                if ($_ ne ".") { 
                 $temp_element = substr($element, 1);
                 $temp_element = $_ . $temp_element;
                }
                
            if (-d $element) {
                $directory = "-directory ";
            }
            my $history = $self->cpf_ct($opts,"lshistory -short -last 1 $directory\"$element\"");
            if ($history !~ m/.*CHECKEDOUT\n/) {
                if ($opts->{opt_DieOnFileChanges}) {
                    $self->cpf_error("Element \"$opts->{scm_path}/$temp_element\" is out of sync "
                            . "with the head");
                } else {
                    $history =~ m/.*@@(.*)\n/;
                    my $merge = $self->cpf_ct($opts,"merge -abort -insert -to "
                            . "\"$element\" -version \"$1\"",
                            {dieOnError => 0});
                    if ($merge =~ m/\*\*\* No Automatic Decision Possible/) {
                        $self->cpf_error("Element \"$opts->{scm_path}/$temp_element\" is out of "
                                . "sync with the head and could not be "
                                . "auto-merged");
                    }
                }
            }
        }

        # Commit the changes using the user-provided commit comment.

        $self->cpf_display("Committing changes");
        foreach my $element (split(/\n/, $elementsToCommit)) {
            $self->cpf_ct($opts,"checkin -c \"$opts->{scm_commitComment}\" \"$element\"");
        }
    
        chdir($orig_dir);
    }
    $self->cpf_display("Changes have been successfully submitted");
}


##########################################################
# cpf_check_multivob
# Determines if the current directory is a multivob repo
#
#
###########################################################
sub cpf_check_multivob{
   my ($self, $opts) = @_;
  
   my $result = "";
   my $command = "cleartool lshistory";

   eval {
        $result = `$command 2>&1`;
   };
   #if cleartool complains about not being a vob object it probabbly means that we have a multivob root
   #in this context, we might need to add further verification like a checkbox in the config.
       
   if ($?) {
       if ($result =~ m/Not an object in a vob/){          
           return 1;
       } elsif ($result =~ m/Cannot get view info for current view/) {           
           return 1;
       } else {
           return 0;
       }      
    } else {
        return 0;
    }   
}

#######################################################################
# Get root directories
# Used in case this is a multivob, to get the individual vob folders
#######################################################################
sub cpf_get_root_directories{
    my ($self, $opts) = @_;
    my $dir = getcwd();
    my $root_dirs;   
    opendir(VRD, $dir) || die("Cannot open directory"); 
    
    my @dirs = readdir(VRD);     
    
    foreach $element (@dirs) {
       if (-d $element) {       
            if (($element ne ".") && ($element ne "..")){
                $root_dirs .= "$element\n" 
            }
       }       
    }   
    closedir(VRD);    
    return $root_dirs;    
}

#------------------------------------------------------------------------------
# driver
#
#       Main program for the application.
#------------------------------------------------------------------------------
sub cpf_driver()
{
    my ($self,$opts) = @_;
    $self->cpf_display("Executing Clearcase actions for ecpreflight");

$::gHelpMessage .= "
ClearCase Options:
  --ccpath <path>           The path to the locally accessible source directory
                            in which changes have been made.
  --ccUnixCSpecPath         The path to a config spec appropriate for the 
                            current view on a unix platform.
  --ccWinCSpecPath          The path to a config spec appropriate for the
                            current view on a windows platform.
  --ccUnixRelativePath      The relative path for the current view on a unix
                            platform from the view root to the directory in 
                            which changes have been made.
  --ccWinRelativePath       The relative path for the current view on a windows
                            platform from the view root to the directory in 
                            which changes have been made.
";

    my %ScmOptions = ( 
        "ccpath=s"              => \$opts->{scm_path},
        "ccUnixCSpecPath=s"     => \$opts->{scm_unixCSpecPath},
        "ccWinCSpecPath=s"      => \$opts->{scm_winCSpecPath},
        "ccUnixRelativePath=s"  => \$opts->{scm_unixRelativePath},
        "ccWinRelativePath=s"   => \$opts->{scm_winRelativePath},
    );

    Getopt::Long::Configure("default");
    if (!GetOptions(%ScmOptions)) {
        error($::gHelpMessage);
    }    

    if ($::gHelp eq "1") {
        $self->cpf_display($::gHelpMessage);
        return;
    }    

    # Collect SCM-specific information.

    $self->extractOption($opts,"scm_path", { required => 1 });
    $self->extractOption($opts,"scm_unixCSpecPath", { required => 0 });
    $self->extractOption($opts,"scm_winCSpecPath", { required => 0 });
    $self->extractOption($opts,"scm_unixRelativePath", { required => 0 });
    $self->extractOption($opts,"scm_winRelativePath", { required => 0 });

    chdir($opts->{scm_path});

    # If the preflight is set to auto-commit, require a commit comment.

    if ($opts->{scm_autoCommit} &&
            (!defined($opts->{scm_commitComment})|| $opts->{scm_commitComment} eq "")) {
        $self->cpf_error("Required element \"scm/commitComment\" is empty or absent in "
                . "the provided options.  May also be passed on the command "
                . "line using --commitComment");
    }
     
    
    if ($self->cpf_check_multivob($opts) eq "1" ) {
        my @vob_root_directories;
        my $directories = cpf_get_root_directories($opts);
        if (defined $directories) {
            @vob_root_directories = split("\n", $directories);
        } else {
            @vob_root_directories = (".");
        }            
               
        foreach (@vob_root_directories) {
           
           my $orig_dir = getcwd();
           if ($_ ne ".") {
                chdir($_);            
           }
           # Error out if the user any files pending a merge.
           my $output = $self->cpf_ct($opts,"findmerge -flatest -print -all", {dieOnError => 0});
            if ($output =~ m/Needs Merge/) {
                $self->cpf_error("Opened files are out of sync with the head. Sync and resolve "
                    . "conflicts, then retry the preflight build");
            }
            chdir($orig_dir);
        }       
    } else {
        # Error out if the user any files pending a merge.

        my $output = $self->cpf_ct($opts,"findmerge -flatest -print -all", {dieOnError => 0});
        if ($output =~ m/Needs Merge/) {
            $self->cpf_error("Opened files are out of sync with the head. Sync and resolve "
                . "conflicts, then retry the preflight build");
        }
    }    
          
        
    if ($self->cpf_check_multivob($opts) eq "1" ) {             
        $opts->{vob_directories} = $self->cpf_get_root_directories($opts);        
        $self->cpf_copyDeltas($opts);        
    }
    else {
    # Copy the deltas to a specific location.        
    $self->cpf_copyDeltas($opts);
    }

    # Auto commit if the user has chosen to do so.

    if ($opts->{scm_autoCommit}) {
        if (!$opts->{opt_Testing}) {
            $self->cpf_waitForJob($opts);
        }
        $self->cpf_autoCommit($opts);
    }
}
1;
