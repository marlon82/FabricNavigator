#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use File::Temp qw(tempfile);
use Net::SSH2;
use Time::HiRes qw(time sleep);

sub value { my $line=<STDIN>; return '' unless defined $line; chomp $line; return decode_base64($line); }
sub fail { my ($code,$message)=@_; print STDERR $message."\n"; exit $code; }
my ($host,$username,$password,$private_key,$passphrase)=map { value() } 1..5;
my $port=<STDIN>;chomp $port if defined $port;$port=($port||'')=~/^\d+$/?int($port):22;
my ($platform,$local_file,$file_name,$activation,$reboot)=map { value() } 1..5;
fail(20,'Invalid firmware deployment request') unless $host=~/^(?:\d{1,3}\.){3}\d{1,3}$/ && length($username) && -f $local_file && $platform=~/^(?:fabricengine|switchengine)$/ && $file_name=~/^[A-Za-z0-9._-]+$/;

my $ssh=Net::SSH2->new(timeout=>20000);fail(21,'SSH connection failed') unless $ssh&&$ssh->connect($host,$port);
my ($authenticated,$key_path)=(0,'');
if(length $password){$authenticated=$ssh->auth(username=>$username,password=>$password)?1:0}
elsif(length $private_key){my($fh,$path)=tempfile('fn-firmware-key-XXXXXX',TMPDIR=>1,UNLINK=>1);$key_path=$path;chmod 0600,$path;print {$fh} $private_key;close $fh;$authenticated=$ssh->auth(username=>$username,privatekey=>$path,passphrase=>$passphrase)?1:0}
fail(22,'SSH authentication failed') unless $authenticated;

sub scp_put {
  my ($local,$remote)=@_;my $ok=eval{$ssh->scp_put($local,$remote);1};return 1 if $ok;
  my @command=('setsid','-w','scp','-O','-q','-P',$port,'-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null');push @command,('-i',$key_path) if length($key_path);push @command,($local,"$username\@$host:$remote");
  my($fh,$ask)=tempfile('fn-firmware-askpass-XXXXXX',TMPDIR=>1,UNLINK=>1);print {$fh} "#!/usr/bin/perl\nprint \$ENV{'FN_SCP_PASSWORD'};\n";close $fh;chmod 0700,$ask;local $ENV{'DISPLAY'}='fabricnavigator';local $ENV{'SSH_ASKPASS'}=$ask;local $ENV{'SSH_ASKPASS_REQUIRE'}='force';local $ENV{'FN_SCP_PASSWORD'}=$password;return system(@command)==0;
}
my $channel=$ssh->channel();fail(23,'SSH channel failed') unless $channel;$channel->blocking(0);$channel->shell();sleep .5;
sub read_idle {my($seconds)=@_;my $output='';my $until=time()+$seconds;while(time()<$until){my $buffer='';my $read=$channel->read($buffer,65536);if(defined($read)&&$read>0){$output.=$buffer;$until=time()+1.5}else{sleep .08}}return $output;}
sub run {my($command,$timeout)=@_;$channel->write($command."\n");return read_idle($timeout||15);}
sub clean {my($value)=@_;$value=~s/\e\[[0-9;?]*[ -\/]*[@-~]//g;$value=~s/\r/\n/g;return $value;}
sub rejected {my($value)=@_;return clean($value)=~/(?:invalid\s+(?:input|command)|unknown\s+command|unrecognized\s+command|command\s+not\s+found|error:|failed)/i;}
read_idle(1);
my ($remote,@commands);
if($platform eq 'fabricengine'){
  $remote='/intflash/'.$file_name;fail(24,'FabricEngine activation image is missing') unless length($activation);
  # Do not use -y here: it is unsupported on some Fabric Engine platforms
  # (including 5520). The interactive confirmation is handled below.
  @commands=('enable',"software add $remote","software activate $activation");push @commands,'reset -y' if $reboot eq 'true';
}else{
  $remote='/usr/local/tmp/'.$file_name;
  @commands=('disable clipaging',"install image $remote inactive");push @commands,'reboot' if $reboot eq 'true';
}
fail(25,"SCP upload to $remote failed") unless scp_put($local_file,$remote);
my $index=0;
for my $command(@commands){$index++;my $timeout=$command=~/^(?:software add|install image)/?1200:$command=~/^(?:software activate)/?300:30;my $output=run($command,$timeout);if($output=~/(?:are you sure|do you want|continue|proceed|overwrite).*?[\[\(]?[yY][\/\\]?[nN]?[\]\)]?/is){$output.=run('y',$command=~/^(?:reboot|reset)/?10:300)}if(rejected($output)){my $reason=clean($output);$reason=~s/\n+/ /g;$reason=substr($reason,0,800);fail(30,"Device rejected step $index ($command): $reason");}}
print "FN_FIRMWARE_STAGED=1\nFN_REMOTE_FILE=$remote\nFN_REBOOT=".($reboot eq 'true'?'true':'false')."\n";
$channel->close();$ssh->disconnect('FabricNavigator firmware deployment complete');exit 0;
