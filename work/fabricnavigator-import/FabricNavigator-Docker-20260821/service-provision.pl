#!/usr/bin/perl
use strict;
use warnings;
use MIME::Base64 qw(decode_base64);
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json);
use Net::SSH2;
use Time::HiRes qw(time sleep);

sub value { my $v=<STDIN>; return '' unless defined $v; chomp $v; return decode_base64($v); }
sub finish { my ($code,$data)=@_; print encode_json($data),"\n"; exit $code; }

my ($host,$username,$password,$private_key,$passphrase)=map { value() } 1..5;
my $port=<STDIN>; chomp $port if defined $port; $port=($port||'')=~/^\d+$/?int($port):22;
my ($action,$vlan,$name,$msti,$isid,$platform)=map { value() } 1..6;
finish(20,{ok=>JSON::PP::false,error=>'Invalid request'}) unless $host=~/^(?:\d{1,3}\.){3}\d{1,3}$/ && $username ne '' && $action=~/^(?:precheck|deploy)$/ && $platform=~/^(?:fabricengine|switchengine)$/ && $vlan=~/^\d+$/ && $vlan>=2 && $vlan<=4059 && $name=~/^[A-Za-z0-9_.-]{1,32}$/ && $msti=~/^\d+$/ && $msti<=63 && $isid=~/^\d+$/ && $isid>=1 && $isid<16777215;
my $ssh=Net::SSH2->new(timeout=>9000);
finish(21,{ok=>JSON::PP::false,error=>'SSH connection failed'}) unless $ssh && $ssh->connect($host,$port);
my $authenticated=0;
if(length $password){$authenticated=$ssh->auth(username=>$username,password=>$password)?1:0}
elsif(length $private_key){my($fh,$path)=tempfile('fn-service-key-XXXXXX',TMPDIR=>1,UNLINK=>1);chmod 0600,$path;print {$fh} $private_key;close $fh;$authenticated=$ssh->auth(username=>$username,privatekey=>$path,passphrase=>$passphrase)?1:0}
finish(22,{ok=>JSON::PP::false,error=>'SSH authentication failed'}) unless $authenticated;
my $channel=$ssh->channel(); finish(23,{ok=>JSON::PP::false,error=>'SSH channel failed'}) unless $channel;
$channel->blocking(0); $channel->shell(); sleep .25;
sub run_command {
  my ($command)=@_; my $output='';
  $channel->write($command."\n");
  my $until=time()+10; my $received=0;
  while(time()<$until){my $buffer='';my $read=$channel->read($buffer,32768);if(defined($read)&&$read>0){$output.=$buffer;$received=1;$until=time()+0.7}else{sleep .07}}
  return $output;
}
my $initial=run_command($platform eq 'switchengine'?'show switch':'show sys-info');
if($platform eq 'switchengine' && $initial=~/(?:VOSS|Fabric Engine|Virtual Services Platform|invalid|error|not found)/i){finish(27,{ok=>JSON::PP::false,host=>$host,error=>'Device platform differs from topology detection (expected SwitchEngine)'})}
if($platform eq 'fabricengine' && $initial=~/(?:ExtremeXOS|Switch Engine)/i){finish(27,{ok=>JSON::PP::false,host=>$host,error=>'Device platform differs from topology detection (expected FabricEngine)'})}
run_command('enable') if $platform eq 'fabricengine';
run_command($platform eq 'switchengine'?'disable clipaging':'terminal length 0');
my $vlan_output=run_command($platform eq 'switchengine'?'show vlan':'show vlan basic');
my $isid_output=run_command($platform eq 'switchengine'?'show fabric attach assignments':'show vlan i-sid');
my $vist_output=$platform eq 'fabricengine'?run_command('show virtual-ist'):'';
if($platform eq 'switchengine' && $isid_output=~/(?:invalid|unknown command|not supported|not licensed|error:)/i){finish(28,{ok=>JSON::PP::false,host=>$host,platform=>$platform,error=>'SwitchEngine does not provide the required Fabric Attach I-SID commands'})}
if($platform eq 'switchengine' && $msti>0){my $stpd_output=run_command("show stpd s$msti");if($stpd_output=~/(?:invalid|unknown|not found|does not exist|error:)/i){finish(29,{ok=>JSON::PP::false,host=>$host,platform=>$platform,error=>"MSTI/STPD s$msti does not exist on the SwitchEngine device"})}}
my ($id_conflict,$name_conflict,$isid_conflict)=(0,0,0);
for my $line(split /\r?\n/,$vlan_output){
  if($platform eq 'switchengine'){
    if($line=~/^\s*(\S+)\s+(\d+)\s+/){$name_conflict=1 if $1=~/^\Q$name\E$/i;$id_conflict=1 if int($2)==int($vlan)}
  }else{
    next unless $line=~/^\s*(\d+)\s+(.+)$/;
    $id_conflict=1 if int($1)==int($vlan);
    $name_conflict=1 if $2=~/(?:^|\s)\Q$name\E(?:\s|$)/i;
  }
}
for my $line(split /\r?\n/,$isid_output){
  if($platform eq 'switchengine'){
    $id_conflict=1 if $line=~/(?:^|\s)\Q$vlan\E(?:\s|$)/;
    $isid_conflict=1 if $line=~/(?:^|\s)\Q$isid\E(?:\s|$)/;
    $name_conflict=1 if $line=~/(?:^|\s)\Q$name\E(?:\s|$)/i;
  }else{
    next unless $line=~/^\s*(\d+)\s+(\d+)\s+/;
    $id_conflict=1 if int($1)==int($vlan);
    $isid_conflict=1 if int($2)==int($isid);
    $name_conflict=1 if $line=~/(?:^|\s)\Q$name\E(?:\s|$)/i;
  }
}
my $partner='';
for my $line(split /\r?\n/,$vist_output){if($line=~/(?:vIST|virtual[- ]?ist|peer)/i && $line=~/((?:\d{1,3}\.){3}\d{1,3})/){$partner=$1;last}}
my @commands=$platform eq 'switchengine'
  ? ("create vlan $name tag $vlan","configure vlan $name add isid $isid",($msti>0?"enable stpd s$msti auto-bind vlan $name":()),'save configuration')
  : ('enable','configure terminal',"vlan create $vlan name $name type port-mstprstp $msti","vlan i-sid $vlan $isid",'exit','save config');
my %result=(ok=>JSON::PP::true,host=>$host,platform=>$platform,vlanConflict=>$id_conflict?JSON::PP::true:JSON::PP::false,nameConflict=>$name_conflict?JSON::PP::true:JSON::PP::false,isidConflict=>$isid_conflict?JSON::PP::true:JSON::PP::false,vistPartner=>$partner,commands=>\@commands);
if($action eq 'deploy'){
  if($id_conflict||$name_conflict||$isid_conflict){$result{ok}=JSON::PP::false;$result{error}='Conflict detected during final precheck';finish(24,\%result)}
  my $configured='';
  my @deploy_commands=$platform eq 'switchengine'?@commands:grep {$_ ne 'enable'} @commands;
  for my $command (@deploy_commands){$configured.=run_command($command)}
  if($configured=~/(?:error|invalid|failed|not found|already exists)/i){$result{ok}=JSON::PP::false;$result{error}='Device rejected the configuration';$result{deviceOutput}=substr($configured,-1500);finish(25,\%result)}
  my $verify=run_command($platform eq 'switchengine'?"show vlan $name fabric attach assignments":'show vlan i-sid');
  my $verified=0;
  for my $line(split /\r?\n/,$verify){if($platform eq 'switchengine'){if($line=~/(?:^|\s)\Q$vlan\E(?:\s|$)/ && $line=~/(?:^|\s)\Q$isid\E(?:\s|$)/){$verified=1;last}}elsif($line=~/^\s*(\d+)\s+(\d+)\s+/ && int($1)==int($vlan) && int($2)==int($isid)){$verified=1;last}}
  unless($verified){$result{ok}=JSON::PP::false;$result{error}='The configured VLAN/I-SID mapping could not be verified';$result{deviceOutput}=substr($verify,-1500);finish(26,\%result)}
  $result{created}=JSON::PP::true;$result{verifiedIsid}=int($isid);
}
$channel->close();$ssh->disconnect('FabricNavigator service provisioning complete');finish(0,\%result);
