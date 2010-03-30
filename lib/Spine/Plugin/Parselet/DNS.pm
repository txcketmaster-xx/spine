
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

use strict;

package Spine::Plugin::Parselet::DNS;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Net::DNS;


our ($VERSION, $DESCRIPTION, $MODULE);
my $resolver;

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Parselet::DNS, Will create an object from DNS";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key/dynamic' => [ { name => "DNS", 
                                                  code => \&dns_key,
                                                  provides => ['dns'] } ],
                     },
          };

# Currently this is a simple example plugin. It should be expanded to allow
# more complicated things to be done.
sub dns_key {
    my ($c, $obj) = @_;

    $resolver = Net::DNS::Resolver->new unless $resolver;

    # Is it for us?
    unless ($obj->get->()->{dynamic_type} =~ m/^\s*dns\s+lookup\s*$/i) {
        return PLUGIN_SUCCESS;
    }
    my $data = $obj->get();
    
    unless (exists $data->{query}) {
        $c->error("Missing 'query' from dns lookup", 'crit');
        return PLUGIN_ERROR;
    }
    
    $data = $data->{query};

    unless (exists $data->{type}) {
        $c->error("Missing query 'type' from dns lookup", 'crit');
        return PLUGIN_ERROR;
    }

    if ($data->{type} =~ m/axfr/i) {
        if (exists $data->{domain}) {
            $obj->set(do_axfr($obj->{domain}));
            return PLUGIN_FINAL;
        }
        $c->error("Missing query 'domain' from AXFR lookup", 'crit');
        return PLUGIN_ERROR;
    } elsif ($data->{type} =~ m/host/i) {
        if (exists $data->{host}) {
            $obj->seT(lookup_host($obj->{host}));
            return PLUGIN_FINAL;
        }
        $c->error("Missing query 'host' from HOST lookup", 'crit');
    }

    $c->error("Unsupported query 'type' from HOST lookup", 'crit');
    return PLUGIN_ERROR;
}

# TODO: expand to support multiple A records
sub lookup_host {
    my $host = shift;
    my $q = $resolver->search($host);
    if ($q) {
        foreach my $rr ($q->answer) {
            next unless $rr->type eq "A";
            return $rr->address;
        }
    }
    return undef;
}

sub do_axfr {
  my ($domain) = @_;
    
  my @zone = $resolver->axfr($domain);
  my %data;
  
  foreach my $rr (@zone) {
      if ($rr->type) {
        $data{$rr->type} = [] unless exists $data{$rr->type};
        push @{$data{$rr->type}}, $rr->name;
      }
  }
  
  return \%data;
}

1;
