use 5.018;
use common::sense;
use utf8;
use MongoDB;
use MongoDB::OID;
use MongoDB::GridFS;
use Data::Dumper;
use Log::Log4perl;
use Getopt::Long;
use Mojolicious::Lite;
use Mojolicious::Plugin::Mongodb;


my $mongoHost="localhost";
my $mongoPort="27017";
my $apiRoot="";
my $apiPort=3000;

GetOptions('mongoHost:s'=> \$mongoHost, 'mongoPort:i'=>\$mongoPort, 
            'apiRoot:s'=> \$apiRoot, 'apiPort:i' => \$apiPort);

my $myUrl="http://" . $apiRoot . "*:" . $apiPort;
app->config(hypnotoad => {listen => [$myUrl]});

#sub startup {
#    my $self = shift;
#    $self->plugin('mongodb', { 
#            host => 'localhost',
#            port => 27017,
#            helper => 'db',
#        });
#}

plugin 'mongodb', { 
    'host'      => $mongoHost,
    'port'      => $mongoPort,
    'helper'    => 'db',
    };

get '/' => {text => 'Hello Wor...ALL GLORY TO THE HYPNOTOAD!'};

app->start;




