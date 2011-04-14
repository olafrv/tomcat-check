#!/usr/bin/perl

###
# FILE: tomcat-check.pl
# DESC: Check tomcat status for hanged up processes.
# AUTHOR: Olaf Reitmaier Veracierta <olafrv@gmail.com>
##

use strict;
use XML::Simple; # libxml-simple-perl
use Data::Dumper; # data-dumper libdata-dumper-simple-perl
use LWP::Simple; # libwww-perl
use MIME::Lite; # libmime-lite-perl libmime-types-perl
use File::Basename;
use URI::Split qw(uri_split);
use Sys::Hostname;
use Sys::Syslog; # all except setlogsock(), or:

my $config = XMLin("tomcat-check.xml");

my $servers = $config->{server};

my $cycle = $config->{cycle};
$cycle = ($cycle eq "" ? 3 : $cycle);

my $syslog = $config->{syslog};
$syslog = ($syslog eq "on" ? 1 : 0);

my $daemon = $config->{daemon};
$daemon = ($daemon eq "on" ? 1 : 0);

my $failed_checks = ();

if (ref($servers) eq 'ARRAY'){
       while (1){
               foreach my $server (@$servers){
                       check_server($server);
               }
               if ($daemon){
                       sleep($cycle);
               }else{
                       print "FAILED: ".keys(%$failed_checks)."\n";
                       exit 0;
               }
       }
}else{
       while (1){
               check_server($servers->{server});
               if ($daemon){
                       sleep($cycle);
               }else{
                       print "FAILED: ".keys(%$$failed_checks)."\n";
                       exit 0;
               }
       }
}

sub check_server{

       my $server = $_[0];

       my $ip = $server->{ip};
       my $port = $server->{port};
       my $user = $server->{user};
       my $password = $server->{password};

       my $checks = $server->{checks};

       my $url = "http://$user:$password\@$ip:$port";
       my $urlHiddenPw = "http://$user:********\@$ip:$port";

       if (ref($checks) eq 'ARRAY'){
               foreach my $check (@$checks){
                       doCheck($url, $check);
               }
       }else{
               doCheck($url, $checks->{check});
       }
}

sub doCheck{
       my $url = $_[0];
       my $check = $_[1];
       my $command = $check->{command};
       if ($command eq "status") {
               doCheckStatus($url . "/manager/status?XML=true", $check);
       }else{
               doLog("error","Wrong command '$command'.", undef);
               exit 2;
       }
}

sub doCheckStatus{

       my $url = $_[0];
       my ($scheme, $auth, $path, $query, $frag) = uri_split($url);
       my $check = $_[1];

       my $check_param = $check->{param};
       my $check_min = $check->{min};
       my $check_max = $check->{max};
       my $check_value = $check->{value};
       my $check_server = substr($auth, index($auth, '@')+1);
       my $alarm_mailto = $check->{alarm}->{mailto};
       my $alarm_subject = "";
       my $alarm_msg = "";

       my $file = "/tmp/tomcat-check-status.xml";

       if (0 && is_error(getstore($url,$file))){
               $alarm_subject = hostname() . " - TOMCAT ERROR - :s - Can't download check URL";
               $alarm_msg = "Server " . $check_server  ." is down or can't download the URL: $url";
               doLog("error", $alarm_msg, undef);
               if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "$alarm_msg\n", undef) };
       }else{

               my $tomcat = XMLin($file);
               my $alarm_msgs = "";
               my $random = int(rand(10));

               my $last_failed_checks_total = 0;

               foreach my $connector (keys %{$tomcat->{connector}}){

                       my $tomcat_ref = $tomcat->{'connector'}->{$connector}->{'workers'}->{'worker'};

                       if (ref($tomcat_ref) eq 'ARRAY'){
				$tomcat_ref = $tomcat_ref;
                       }else{
				$tomcat_ref = [$tomcat_ref];
                       }

			print Dumper($tomcat_ref);

                       foreach my $worker (@$tomcat_ref){

                               my $value = $worker->{$check_param};
                               my $method = $worker->{method};
                               my $uri = $worker->{currentUri};
                               my $qs = $worker->{currentQueryString};
                               my $failed_checks_ref = $failed_checks->{"$check_server"};

				print $connector . $method . $uri . $qs . "\n";
				
                               if (!($check_min eq "") && !($check_max eq "")){
                                       if ($value < $check_min or $value > $check_max){
                                               if (defined $failed_checks_ref->{"$uri$qs"}){
                                                       # Another failure
                                                       $failed_checks_ref->{"$uri$qs"}->{'current'} += 1;
                                               }else{
                                                       # First failure
                                                       $failed_checks_ref->{"$uri$qs"}->{'current'} = 1;
                                                       $failed_checks_ref->{"$uri$qs"}->{'last'} = 0;
                                                       $failed_checks_ref->{"$uri$qs"}->{'connector'} = $connector;
                                                       $failed_checks_ref->{"$uri$qs"}->{'value'} = $value;
                                                       $failed_checks_ref->{"$uri$qs"}->{'method'} = $method;
                                               }
                                       }
                               }
                       }

                       for (keys %$failed_checks){

                               my $failed_checks_ref = $failed_checks->{"$check_server"}->{$_};

                               $last_failed_checks_total += $failed_checks_ref->{'last'};

                               if ($failed_checks_ref->{'current'} > $failed_checks_ref->{'last'}){
                                       $alarm_msg = "$check_server / "
                                               . $failed_checks_ref->{connector}
                                               . " check_param=" . $failed_checks_ref->{value} . " (r:$check_min-$check_max) "
                                               . $failed_checks_ref->{method} . ":" . $_;
                                       doLog("alert", $alarm_msg, undef);
                                       $alarm_msgs = $alarm_msgs . "\n" . getTimeString() . " " . $alarm_msg;
                               }elsif (($failed_checks_ref->{'current'}) == 0){
                                       $failed_checks_ref->{'last'} = 0;
                               }

                               # Convert the current number of failed checks in the last
                               $failed_checks_ref->{'last'} = $failed_checks_ref->{'current'};

                       }
               }

               if ($alarm_msgs ne "")
               {
                       # Alarm is ON there are new failed checks and we need to send alarm ON messages.
                       $alarm_subject = "$check_server - TOMCAT ALARM [ON] - :( - $check_param outside range";
                       doLog("alert", $alarm_subject, undef);
                       if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "$alarm_msgs\n", undef) };
               }
               elsif ($last_failed_checks_total > 0)
               {
                       # All things are OK because failed checks disappear we send an OK messON age.
                       $alarm_subject = "$check_server - TOMCAT [OK] - :)";
                       doLog("info", $alarm_subject, undef);
                       if ($alarm_mailto ne "") { doAlarmMail($alarm_mailto, $alarm_subject, "All is ok.-\n", undef) };

               }
       }

}

sub doLog(){
       my $priority = $_[0]; # info,notice,warn,error
       my $msg = $_[1]; # string value
       my $obj = $_[2]; # undef or reference
       if ($syslog){
               openlog ("tomcat-check", "cons,pid", "syslog");
               syslog ($priority, "%s", $msg);
               closelog;
       }else{
               print "tomcat-check - $priority: $msg\n";
       }
}

sub getTimeString(){
       my ($sec,$min,$hour,$mday,$mon,$year,$wday,
       $yday,$isdst)=localtime(time);
       my $result = sprintf "%4d-%02d-%02d %02d:%02d:%02d",$year+1900,$mon+1,$mday,$hour,$min,$sec;
       return $result;
}

sub doAlarmMail(){
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
       $msg->send;
}
