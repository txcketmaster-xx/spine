
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

package Spine::Plugin::Parselet::Basic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use File::Spec::Functions;

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::Basic, processes Basic keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Basic_Final", 
                                          code => \&_parse_basic_key,
                                          position => HOOK_END },
                                        { name => "Basic_Init", 
                                          code => \&_init_key,
                                          position => HOOK_START }, ],
                     },
          };

sub _parse_basic_key {
    my ($c, $data) = @_;

    # Skip refs, only scalars
    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }
    
    my $obj = [split(m/\n/o, $data->{obj})];
    my $keyname = $data->{keyname};

    if (exists($c->{$keyname})) {
        my $existing = ref($c->{$keyname});
        unless ($existing eq 'ARRAY') {
            $c->error("Mismatched types for $keyname: It seems that "
                         . "you're trying to use a list on a \""
                         . lc($existing) . '"', 'crit');
            return undef;
        }
    } else {
        # Don't create empty keys
        if ($keyname) {
             $c->{$keyname} = [];
        }
    }

    my @final;

    # Now walk the list looking for control characters and interpreting
    # where necessary.  Otherwise, just append it to the list
    foreach (@{$obj}) {
        # Ignore comments and blank lines.
        if (m/^\s*$/o or m/^\s*#/o) {
            next;
        }

        # We allow several metacharacters to manipulate
        # pre-existing values in a key.  -regex removes
        # matching values for the key in question.
        if ($keyname && m/^-(.*)$/o) {
            next unless defined @{$c->{$keyname}};

            my $rm_regex = $1;
            @{$c->{$keyname}} = grep(!/$rm_regex/, @{$c->{$keyname}});

            next;
        }

        # If equals (=) is the first and only character of
        # a line, clear the array.  This is used to set
        # absolute values.
        elsif ($keyname && m/^=\s*$/o) {
            delete $c->{$keyname} if defined($keyname);
            next;
        }

        # If there isn't a control character, just append it.
        #push @{$c->{$keyname}}, $_;
        push @final, $_;
    }
    $data->{obj} = \@final;

    return PLUGIN_FINAL;
}

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
