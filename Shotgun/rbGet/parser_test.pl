use 5.018;
use Data::Dumper;
use Time::HiRes qw/time/;
use FindBin;
use lib $FindBin::Bin;
require "RateBeerCrawl.pm";

my $loops=80;
my @files = qw/
1.html
2.html
3.html
4.html
/;

my $parser = Beerhunter::BeerData::RateBeerCrawl->new(); 
my $timer = time;
my $filesNo = @files;
my $parsedTime = $filesNo*($loops+1);

say "running $parsedTime jobs.";
$|=1;
for (0 .. $loops){
    foreach my $fname (@files){
        local $/=undef;
        open FILE, $fname or die;
        binmode FILE;
        my $html = <FILE>;
        my $parsed=$parser->parse_html($html);
        close FILE;
        print ".";
        # say Dumper($parsed);
    }
}
print "\n";

$timer = time - $timer;
my $speed = $timer/$parsedTime;
my $throttle = $parsedTime/$timer;
say "Parsing speed was: $speed (s/page). Pages/s: $throttle";

