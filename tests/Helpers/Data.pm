package Helpers::Data;
use Spine::Data;
use Spine::Registry;
use File::Spec::Functions;

my %configs = (
    "basic" => {
        spine => { Profile => "fake_profile" },
        fake_profile => { TestPoint => "TestCase" },
    },
);

sub new_data_obj {
  my $userconf = shift || "basic";
  my $croot = shift || "test_root";

  my $conf = $configs{$userconf};
  
  my $reg = new Spine::Registry($conf);

  my $data = Spine::Data->new( croot => "test_root",
                               config => $conf,
                               release => 1);
                             
  return $data, $reg;
}

1;