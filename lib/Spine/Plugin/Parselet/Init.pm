
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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

package Spine::Plugin::Parselet::Init;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use YAML::Syck;

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::Init, initial expansion of keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Init", 
                                          code => \&_init_key,
                                          position => HOOK_START } ],
                     },
          };


# Does lots of preprocessing ready for the other key parsers
sub _init_key {
    my ($c, $data) = @_;

    # If the object doesn't exists then we probably
    # need to process a file.
    my $fh = undef;
    unless (defined $data->{obj}) {
        my $file = $data->{file};
        unless (-f $file) {
            $file = catfile($c->{c_croot}, $file);
            if (-f $file) {
                $data->{file} = $file;
            }
        }
        unless (-r $file) {
            $c->error("Can't read file \"$file\"", 'crit');
            return PLUGIN_ERROR;
        }
        $fh = new IO::File("<$file");
        unless (defined($fh)) {
            $c->error("Failed to open \"$file\": $!", 'crit');
            return PLUGIN_ERROR;
        }
        $c->print(4, "reading key $file");
    }

    # loop through either array's of scalars or file handles
    if (defined($fh) || (ref($data->{obj}) eq "ARRAY") && !ref($data->{obj}[0])) {
        my $buf = "";
        my $line = undef;
        while ($line = ((defined $fh && <$fh>) || shift @{$data->{obj}})) {
            # Some template preprocessing (XXX not nice)
            if ($line =~ m/\[%/o) {
                # XXX: to be removed
                $line = _convert_lame_to_TT($line);
                # FIXME: if we have detected template in this key we have to strip out any
                # template lines which are commented out. Otherwise TT might blow up
                if ($line =~ m/^\s*#/o) {
                    next;
                }
                # We flag it as a templatized file for a minor performance gain
                if (not exists($data->{template})) {
                    $data->{template} = undef;
                }
            }
            $buf .= $line;
        }
        if (defined ($fh)) {
            $fh->close();
        }
        $data->{obj}=$buf;
    }

    return PLUGIN_SUCCESS;
}

# XXX: to be removed
#
# _convert_lame_to_TT tweaks the lame ass TT-like MATCH syntax I created with
# actual TT logic so that it can all be processed by TT directly.
#
sub _convert_lame_to_TT
{
    my $line = shift;

    # If it's not one of our lame syntax lines, just return it
    unless ($line =~ m/^\[%(\s*)(IF|MATCH|ELSIF)\s+(.+\s*)+%\]\s*$/o) {
        return $line;
    }

    my $new  = "[\%$1"; # $1 should be the amount of whitespace
    $new .= ($2 eq 'MATCH' or $2 eq 'IF') ? 'IF' : 'ELSIF';
    $new .= ' ';
    my $criteria = $3;

    # If there isn't a semi-colon, it's not one of ours
    unless ($criteria =~ qr/;\s*/) {
        return $line;
    }

    my @querystring = split(/;\s*/, $criteria);
    my @conditions;

    foreach my $condition (@querystring) {
        my ($var, $regex) = split(/=/, $condition, 2);

        push @conditions, "c.$var.search('$regex')";
    }

    $new .= join(' AND ', @conditions);
    $new .= " \%]\n";
    return $new;
}


1;
