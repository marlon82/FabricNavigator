#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64 qw(decode_base64 encode_base64);
use File::Temp qw(tempfile);
use Fcntl qw(O_RDONLY);
use Net::SSH2;
use Time::HiRes qw(time sleep);

sub value { my $line=<STDIN>; return '' unless defined $line; chomp $line; return decode_base64($line); }
sub fail { my ($code,$message)=@_; print STDERR $message."\n"; exit $code; }

my ($host,$username,$password,$private_key,$passphrase)=map { value() } 1..5;
my $port=<STDIN>; chomp $port if defined $port; $port=($port||'')=~/^\d+$/?int($port):22;
my ($action,$requested_platform,$configuration,$archive_data)=map { value() } 1..4;
fail(20,'Invalid backup request') unless $host=~/^(?:\d{1,3}\.){3}\d{1,3}$/ && length($username) && $port>0 && $port<65536 && $action=~/^(?:backup|restore)$/;

my $ssh=Net::SSH2->new(timeout=>12000);
fail(21,'SSH connection failed') unless $ssh && $ssh->connect($host,$port);
my $authenticated=0;my $key_path='';
if(length $password){$authenticated=$ssh->auth(username=>$username,password=>$password)?1:0}
elsif(length $private_key){my($fh,$path)=tempfile('fn-config-key-XXXXXX',TMPDIR=>1,UNLINK=>1);$key_path=$path;chmod 0600,$path;print {$fh} $private_key;close $fh;$authenticated=$ssh->auth(username=>$username,privatekey=>$path,passphrase=>$passphrase)?1:0}
fail(22,'SSH authentication failed') unless $authenticated;
my $channel=$ssh->channel();fail(23,'SSH channel failed') unless $channel;
$channel->blocking(0);$channel->shell();sleep .35;

sub read_until_idle {
  my ($timeout)=@_;my $output='';my $until=time()+$timeout;my $received=0;
  while(time()<$until){my $buffer='';my $read=$channel->read($buffer,65536);if(defined($read)&&$read>0){$output.=$buffer;$received=1;$until=time()+.9}else{sleep .06}}
  return $output;
}
sub run_command { my ($command,$timeout)=@_;$channel->write($command."\n");return read_until_idle($timeout||12); }
sub clean_output { my ($value)=@_;$value=~s/\e\[[0-9;?]*[ -\/]*[@-~]//g;$value=~s/\r/\n/g;$value=~s/\n{3,}/\n\n/g;return $value; }
sub openssh_scp_get {
  my ($remote,$local)=@_;my @command=('setsid','-w','scp','-O','-q','-P',$port,'-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null');
  push @command,('-i',$key_path) if length($key_path);push @command,("$username\@$host:$remote",$local);
  my ($ask_fh,$ask_path)=tempfile('fn-scp-askpass-XXXXXX',TMPDIR=>1,UNLINK=>1);print {$ask_fh} "#!/usr/bin/perl\nprint \$ENV{'FN_SCP_PASSWORD'};\n";close $ask_fh;chmod 0700,$ask_path;
  local $ENV{'DISPLAY'}='fabricnavigator';local $ENV{'SSH_ASKPASS'}=$ask_path;local $ENV{'SSH_ASKPASS_REQUIRE'}='force';local $ENV{'FN_SCP_PASSWORD'}=$password;
  return system(@command)==0 && -s $local;
}
sub openssh_scp_put {
  my ($local,$remote)=@_;my @command=('setsid','-w','scp','-O','-q','-P',$port,'-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null');
  push @command,('-i',$key_path) if length($key_path);push @command,($local,"$username\@$host:$remote");
  my ($ask_fh,$ask_path)=tempfile('fn-scp-askpass-XXXXXX',TMPDIR=>1,UNLINK=>1);print {$ask_fh} "#!/usr/bin/perl\nprint \$ENV{'FN_SCP_PASSWORD'};\n";close $ask_fh;chmod 0700,$ask_path;
  local $ENV{'DISPLAY'}='fabricnavigator';local $ENV{'SSH_ASKPASS'}=$ask_path;local $ENV{'SSH_ASKPASS_REQUIRE'}='force';local $ENV{'FN_SCP_PASSWORD'}=$password;
  return system(@command)==0;
}

read_until_idle(1);
sub rejected { my ($value)=@_;return $value=~/(?:invalid\s+(?:input|command)|unknown\s+command|unrecognized\s+command|command\s+not\s+found|error:\s*(?:invalid|unknown))/i; }
sub usable_configuration { my ($value)=@_;return !rejected($value)&&$value=~/\S/&&length($value)>80; }
sub configuration_probe {
  my ($candidate)=@_;
  if($candidate eq 'fabricengine'){
    run_command('enable',4);
    run_command('terminal more disable',4);
    return ('show running-config',clean_output(run_command('show running-config | no-more',45)));
  }
  run_command('disable clipaging',4);
  return ('show configuration',clean_output(run_command('show configuration',35)));
}

my $identity=clean_output(run_command('show switch',7).run_command('show sys-info',7).run_command('show version',7));
my $software_version='';
if($identity=~/(?:software\s+version|software\s+release|image\s+version|extremexos\s+version|primary\s+ver(?:sion)?)\s*(?::|=|is)?\s*[vV]?([0-9]+(?:\.[0-9A-Za-z_-]+){1,7})/i){$software_version=$1}
my $platform=$requested_platform;
if($platform!~/^(?:fabricengine|switchengine)$/){
  if($identity=~/(?:ExtremeXOS|Switch\s*Engine|\bEXOS\b)/i){$platform='switchengine'}
  elsif($identity=~/(?:Fabric\s*Engine|\bVOSS\b|Virtual\s+Services\s+Platform|\bVSP[-\s]|:\d+[>#]\s*$)/im){$platform='fabricengine'}
}

my ($command,$output);
if($action eq 'backup'){
  if($platform=~/^(?:fabricengine|switchengine)$/){($command,$output)=configuration_probe($platform)}
  else{
    ($command,$output)=configuration_probe('fabricengine');
    if(usable_configuration($output)){$platform='fabricengine'}
    else{($command,$output)=configuration_probe('switchengine');$platform='switchengine' if usable_configuration($output)}
  }
  fail(24,'Unsupported device platform; configuration commands for FabricEngine/VSP and SwitchEngine/EXOS were rejected') unless $platform=~/^(?:fabricengine|switchengine)$/ && usable_configuration($output);
  $output=~s/^.*?\Q$command\E\s*\n//s;
  $output=~s/^\s*Command Execution Time:.*\n//mig;
  $output=~s/^#\s+(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\w+\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}\s+\w+\s*\n?//mig;
  fail(25,'The device returned no configuration') unless $output=~/\S/;
  my ($archive_name,$archive_base64)=('','');
  if($platform eq 'fabricengine'){
    my $base='/intflash/fabricnavigator-'.int(time());
    my $backup_output=clean_output(run_command("backup configure $base",120));
    if(rejected($backup_output)){my $reason=$backup_output;$reason=~s/[\r\n]+/ /g;$reason=substr($reason,0,500);fail(30,'backup configure was rejected; an RWA account is required. Device response: '.$reason)}
    my ($fh,$local)=tempfile('fn-config-archive-XXXXXX',TMPDIR=>1,UNLINK=>1);close $fh;
    my $remote='';
    for my $candidate("$base.tgz","$base.zip"){
      if(eval{$ssh->scp_get($candidate,$local);1} && -s $local){$remote=$candidate;last}
      my $downloaded=eval{
        my $sftp=$ssh->sftp();my $source=$sftp->open($candidate,O_RDONLY);open my $target,'>',$local or die 'open';binmode $target;
        my $buffer='';while(1){my $read=$source->read($buffer,65536);last unless defined($read)&&$read>0;print {$target} substr($buffer,0,$read)}close $target;1;
      };
      if($downloaded && -s $local){$remote=$candidate;last}
      if(openssh_scp_get($candidate,$local)){$remote=$candidate;last}
    }
    unless(length($remote)&&-s $local){my $reason=$backup_output;$reason=~s/[\r\n]+/ /g;$reason=substr($reason,0,500);fail(31,'The full backup archive could not be downloaded from the switch. Device response: '.$reason)}
    open my $archive,'<',$local or fail(32,'The downloaded backup archive could not be opened');binmode $archive;local $/;my $bytes=<$archive>;close $archive;
    fail(33,'The downloaded backup archive is invalid') unless defined($bytes)&&length($bytes)>32;
    $archive_name=$remote;$archive_name=~s{.*/}{};$archive_base64=encode_base64($bytes,'');
    run_command("delete $remote",3);run_command('y',3);
  }
  print "FN_PLATFORM=$platform\n";
  print "FN_SOFTWARE_VERSION=$software_version\n" if length($software_version);
  print "FN_ARCHIVE_NAME=$archive_name\nFN_ARCHIVE_BEGIN\n$archive_base64\n" if length($archive_base64);
  print "FN_CONFIG_BEGIN\n$output";
}else{
  fail(24,'Unsupported restore platform') unless $platform=~/^(?:fabricengine|switchengine)$/;
  my ($probe_command,$probe_output)=configuration_probe($platform);
  fail(26,'Restore platform does not match the detected device platform') unless usable_configuration($probe_output);
  fail(26,'Restore platform does not match detected device platform') unless $requested_platform eq $platform;
  fail(27,'The selected configuration is empty') unless $configuration=~/\S/;
  if($platform eq 'fabricengine' && length($archive_data)){
    my ($fh,$local)=tempfile('fn-restore-XXXXXX',SUFFIX=>'.tgz',TMPDIR=>1,UNLINK=>1);binmode $fh;print {$fh} $archive_data;close $fh;
    my $remote='/intflash/fabricnavigator-restore-'.int(time()).'.tgz';
    my $uploaded=eval{$ssh->scp_put($local,$remote);1};$uploaded=openssh_scp_put($local,$remote) unless $uploaded;
    fail(34,'The full backup archive could not be uploaded to the switch') unless $uploaded;
    my $restore_output=clean_output(run_command("restore configure $remote",180));
    fail(35,'The switch rejected restore configure') if rejected($restore_output);
    print "FN_PLATFORM=$platform\nFN_RESTORED_ARCHIVE=1\n";
    $channel->close();$ssh->disconnect('FabricNavigator configuration restore complete');exit 0;
  }
  my @commands;
  for my $line(split /\r?\n/,$configuration){
    $line=~s/^\s+|\s+$//g;
    next if $line eq ''||$line=~/^(?:!|#|\*|FN_|show\s+(?:running-config|configuration)|.*[>#]\s*)$/i;
    next if $line=~/(?:password|community|secret)\s*[:=]\s*\*+/i;
    push @commands,$line;
  }
  fail(28,'No restorable configuration commands were found') unless @commands;
  run_command('configure terminal',5) if $platform eq 'fabricengine';
  my $output='';my $count=0;
  for my $command(@commands){$output.=run_command($command,7);$count++;if($output=~/(?:invalid command|unknown command|failed|error:)/i){fail(29,"Device rejected restore command $count: $command")}}
  if($platform eq 'fabricengine'){run_command('exit',4);run_command('save config',15)}else{run_command('save configuration',15)}
  print "FN_PLATFORM=$platform\nFN_RESTORED=$count\n";
}
$channel->close();$ssh->disconnect('FabricNavigator configuration backup complete');
exit 0;
