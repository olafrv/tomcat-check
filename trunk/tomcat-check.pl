#!/usr/bin/perl

###
# FILE: tomcat-check.pl
# DESC: Do checks against tomcat parsing the /manager xml output
# WARNING: Tested with Apache Tomcat 6.0.29
# AUTHOR: Olaf Reitmaier Veracierta <olafrv@gmail.com>
# LICENSE: GNU/GPL 3.0 or later
##

use strict;
use warnings;
use Data::Dumper; # libdata-dumper-simple-perl
use XML::Simple; # libxml-simple-perl
use LWP::Simple; # libwww-perl
use MIME::Lite; # libmime-lite-perl libmime-types-perl
use Sys::Syslog; # all except setlogsock()
use Proc::Daemon; # libproc-daemon-perl
use Proc::PID::File; # libproc-pid-file-perl
use URI::Split qw(uri_split);
use File::Basename;
use Sys::Hostname;
use Fcntl ':mode';

my $continue = 1; # Flag to stop thread in daemon mode 
my $debug = 0; # By default don't show debug messages
my $debuglevel = 0; # By default use the basic debug level
my $syslog = 1;  # By default write to syslog
my $mail = 1; # By default send email
my $cycle = 20; # Run checks every 20 seconds cycle
my $failed_checks = {}; # Failed checks for all commands

sub check_server{

        my $server = $_[0]; # The XML data of server to be checked

        my $ip = $server->{ip};
        my $port = $server->{port};
        my $user = $server->{user};
        my $password = $server->{password};

    # Navigate to checks in XML config
        my $checks = $server->{checks}->{check}; # List of XML data of the checks to be performed
        $checks = ref($checks) eq 'ARRAY' ? $checks : [$checks];

        my $url = "http://$user:$password\@$ip:$port";
        my $urlDebug = "http://$user:********\@$ip:$port";

    #if ($debug) { doLog("info", "Checking $urlDebug", undef) };
    doLog("info", "Checking $urlDebug", undef);

        foreach my $check (@$checks){

        if ($debug && !$syslog && $debuglevel>1) { doLog("info", "Variable \$failed_checks is ", $failed_checks)};

        doCheck($url, $check);

        if ($debug && !$syslog && $debuglevel>1) { doLog("info", "Variable \$failed_checks is ", $failed_checks)};
        }


}

sub doCheck{
        my $url = $_[0]; # The root URL of tomcat
    my $check = $_[1]; # The check to be done

    my $command = $check->{command}; # The command to do the check

    if ($command eq "status"){    
           if ($debug) {doLog("info", "Downloading /manager/status?XML=true", undef)};
               doCheckStatus($url . "/manager/status?XML=true", $check);
           }else{
               doLog("err","Wrong command '$command'.", undef);
               exit 2;
        }
}

sub doCheckStatus{

       my $url = $_[0];
       my ($scheme, $auth, $path, $query, $frag) = uri_split($url);
       my $check = $_[1];

       my $check_number = $check->{number};
       my $check_param = $check->{param};
       my $check_min = $check->{min};
       my $check_max = $check->{max};
       my $check_value = $check->{value};
       my $check_server = substr($auth, index($auth, '@')+1);

       my $alarm_mailto = $check->{alarm}->{mailto};
       my $alarm_subject = "";
       my $alarm_msg = "";

       my $file = "/tmp/tomcat-check-status.xml"; # TMP file to save XML output from Tomcat

       if (is_error(getstore($url,$file))){
               $alarm_subject = hostname() . " - TOMCAT ERROR - :s - Can't download check URL";
               $alarm_msg = "Server " . $check_server  ." is down or can't download the URL: $url";
               doLog("err", $alarm_msg, undef);
               if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "$alarm_msg\n", undef) };
       }else{

               my $tomcat = XMLin($file); # Load XML output from Tomcat /manager 

               foreach my $connector (keys %{$tomcat->{connector}}){
                  
                           my $alarm_msgs = ""; # Concatenated alarm messages
                my $last_failed_checks_total = 0; # Last server status check failures count
                my $current_failed_checks_total = 0; # Current server status check failures count
                my $i = 0; # Processed request count

            # Navegate to workers in the XML downloaded from tomcat
                        my $tomcat_ref = $tomcat->{'connector'}->{$connector}->{'workers'}->{'worker'};
                        $tomcat_ref = ref($tomcat_ref) eq 'ARRAY' ? $tomcat_ref : [$tomcat_ref];

            # Hash for check result by server of the check
                if (!(defined $failed_checks->{status}->{"$check_server"})) { $failed_checks->{status}->{"$check_server"} = {} };
                my $failed_checks_ref = $failed_checks->{status}->{"$check_server"};

            # Hash for check results by number of the check
            if (!(defined $failed_checks_ref->{"$check_number"})) { $failed_checks_ref->{"$check_number"} = {} };
                        $failed_checks_ref = $failed_checks_ref->{"$check_number"};

            # Hash for check results by connector of the check
            if (!(defined $failed_checks_ref->{"$connector"})) { $failed_checks_ref->{"$connector"} = {} };
                        $failed_checks_ref = $failed_checks_ref->{"$connector"};

            foreach my $worker (@$tomcat_ref){

                               my $value = $worker->{$check_param};
                               my $method = $worker->{method};
                               my $uri = $worker->{currentUri};
                               my $qs = $worker->{currentQueryString};
                   my $remoteAddr = $worker->{remoteAddr};
                   my $virtualHost = $worker->{virtualHost};

                   my $index = "$virtualHost $method $uri $qs"; # Groupping key for failed requests
            
                   if ($debug && !$syslog && $debuglevel>1) { doLog("info", "Variable \$worker is ", $worker)};
       
                               if (!($check_min eq "") && !($check_max eq "")){
                                       if ($value < $check_min or $value > $check_max){
                                               if (defined $failed_checks_ref->{"$index"}){
                                                        $failed_checks_ref->{"$index"}->{'current'} += 1;
                            if ($debug) {
                                doLog(
                                    "info","srv:$check_server, chk:$check_number, conn:$connector" 
                                    . " - Another failed check value=$value for this '$index'", undef
                                );
                            }
                                               }else{
                            $failed_checks_ref->{"$index"} = {};
                                                        $failed_checks_ref->{"$index"}->{'current'} = 1;
                                                        $failed_checks_ref->{"$index"}->{'last'} = 0;
                                                        $failed_checks_ref->{"$index"}->{'connector'} = $connector;
                                                        $failed_checks_ref->{"$index"}->{'value'} = $value;
                                                        $failed_checks_ref->{"$index"}->{'method'} = $method;
                            if ($debug) {
                                doLog(
                                    "info","srv:$check_server, chk:$check_number, conn:$connector"
                                    . " - Fisrt failed check value=$value for this '$index'", undef
                                );
                            }
                                               }
                                       }
                               }else{
                    if ($debug) {doLog("info", "Missing min and max value for check in config XML.", undef)};
                   }
                   $i++;
                        }

                if ($debug) { doLog("info", "$connector - Processed $i request(s)", undef) };
        
            for (keys %$failed_checks_ref){

                                   my $failed_check_ref = $failed_checks_ref->{$_};

                                   $last_failed_checks_total += $failed_check_ref->{'last'};
                                   $current_failed_checks_total += $failed_check_ref->{'current'};

                                if ($failed_check_ref->{'current'} > $failed_check_ref->{'last'})
                {
                                    $alarm_msg = "$check_server / "
                                               . $failed_check_ref->{connector}
                                               . " ($check_min >= !value=" . $failed_check_ref->{value} . " <= $check_max) "
                                               . $_;
                                        $alarm_msgs = $alarm_msgs . "\n" . getTimeString() . " " . $alarm_msg;
                                  }

                                # Convert the current number of failed checks in the last
                                $failed_check_ref->{'last'} = $failed_check_ref->{'current'};
                                $failed_check_ref->{'current'} = 0;
                       }
                
               if ($debug) { doLog("info", "$connector - Total last failed checks $last_failed_checks_total", undef) };    
               if ($debug) { doLog("info", "$connector - Total current failed checks $current_failed_checks_total", undef) };    

                   if ($alarm_msgs ne "")
                   {
                   # Failed checks grow and alarm messages are generated for each one
                           $alarm_subject = "$check_server - TOMCAT [$connector] -  :(  - ALARM!!!";
                           doLog("info", $alarm_subject, undef);
                           if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "$alarm_msgs\n", undef) };
                   }
                   elsif (($last_failed_checks_total > 0) && ($current_failed_checks_total == 0))
                   {
                   # There no alarm messages and failed checks to zero    
                           $alarm_subject = "$check_server - TOMCAT [$connector] -  :)  - OK.";
                           doLog("info", $alarm_subject, undef);
                           if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "All is ok.-\n", undef) };
                   }
           }
       }
}


sub doAlarmMail{
    my $alarm_mailto = $_[0];
        my $alarm_subject = $_[1];
    my $alarm_msg = $_[2];
        my $file = $_[3];

        my $msg = MIME::Lite->new(From=>"root\@" . hostname(),
                                    To=>$alarm_mailto,
                                    Cc=>"",
                                    Subject=>$alarm_subject,
                             Type=>"multipart/mixed");

    $msg->attach(Type =>'TEXT',  Data =>$alarm_msg);

        if (defined $file){
        $msg->attach(Type =>'TEXT',
                             Path     => $file,
                                Filename => basename($file),
                             Disposition => 'attachment');
    }

    if ($mail){
        $msg->send();
            if ($msg->last_send_successful()){
            doLog("info","Sent mail to '$alarm_mailto'", undef);
        }else{
            doLog("err", "Can't send mail to '$alarm_mailto'", undef);
        }        
    }else{
        if ($debug) { 
            doLog("info","Mailing is disabled, discarded mail to '$alarm_mailto'.", undef);
        }
    }
}


sub doLog{
        my $priority = $_[0] eq "" ? "info" : $_[0]; # info,error
        my $msg = $_[1]; # string
        my $obj = $_[2]; # undef or ref
    if (defined $obj){
        $msg = $msg . " " . Dumper($obj);
    }
        if ($syslog){
        print "$priority\n";
                openlog ("tomcat-check", "cons,pid", "syslog");
                syslog ("$priority|syslog", "%s", $msg);
                closelog;
        }else{
                print getTimeString() . " - $priority: $msg\n";
        }
}


sub getTimeString{
       my ($sec,$min,$hour,$mday,$mon,$year,$wday,
       $yday,$isdst)=localtime(time);
       my $result = sprintf "%4d-%02d-%02d %02d:%02d:%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec;
       return $result;
}

my $config_file_name = "/etc/tomcat-check.xml";
my $config = undef;

if (-e $config_file_name){
    my @mode = stat($config_file_name);
    my $u_mode = ($mode[2] & S_IRWXU) >> 6;
    my $g_mode = ($mode[2] & S_IRWXG) >> 3;
    my $o_mode = ($mode[2] & S_IRWXO);
    if ($u_mode == 7 && $g_mode == 0 && $o_mode==0 && $mode[4]==0 && $mode[5]==0){
        $config = XMLin($config_file_name);
    }else{
        print "Wrong $config_file_name permissions must be u:root,g:root,0700\n";
        exit 1;
    }
}else{
    print "None config file '$config_file_name' exists\n";
    exit 1;
}

my $daemon = $config->{daemon} eq "on" ? 1 : 0; # run as daemon?

my $pidfile = undef; # /var/run/tomcat-check.pid

if ($daemon){
    my $daemon_name = substr(basename($0), 0, length(basename($0))-3); 
    if (-e "/var/run/$daemon_name.pid"){
        print "PID file exists, already running!\n";    
        exit 1;
    }
    Proc::Daemon::Init; # Prepare to fork and daemonize
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { $continue = 0 }; # Signal catching
    $SIG{PIPE} = 'ignore';
    $pidfile = Proc::PID::File->running(name => $daemon_name); # Pid file creating
}

my $servers = $config->{server}; # Navigate to servers in XML config
$servers = ref($servers) eq 'ARRAY' ? $servers : [$servers];

$cycle = $config->{cycle} ? 3 : $config->{cycle}; # cycle time of main thread in seconds?
$debug = $config->{debug} eq "on" ? 1 : 0;
$debuglevel = $config->{debuglevel} eq "" ? 0 : int($config->{debuglevel});
$syslog = $config->{syslog} eq "on" ? 1 : 0;
$mail = $config->{mail} eq "on" ? 1 : 0;

$failed_checks->{status} = {}; # Failed checks for the status command

if ($debug && !$syslog && $debuglevel>1) { 
    doLog("info", "Here is the configuration:", $config);
}

while ($continue){    
    foreach my $server (@$servers){
            check_server($server);
    }
        if ($daemon){
            sleep($cycle);
        }else{
        $continue = 0;
    }
}

if ($daemon){
    $pidfile->release();
}

exit 0;

