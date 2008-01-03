# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Parser;

use strict;
use base qw(Exporter);
our (@EXPORT_OK, $CURRENT_DEPTH, $MAX_NESTING_DEPTH);

@EXPORT_OK = qw($MAX_NESTING_DEPTH);

use IO::File;
use Spine::Registry;
use File::Spec::Functions;

use YAML::Syck;
use JSON::Syck;

$CURRENT_DEPTH = 0;
$MAX_NESTING_DEPTH = 7;

sub new
{
    my $class = shift;
    my %args = @_;

    my $registry = new Spine::Registry();

    bless { __root => $args{Path} || '',
            __registry => $registry }, $class;
}


# This is a public interface to _read_keyfile below.  An underscore prefix on
# a member variable or method traditionally means that member is a privately
# scoped method and shouldn't be called outside the object or its inheritors.
#
# rtilder    Thu Jun  8 13:05:55 PDT 2006
sub read_keyfile
{
    my $self = shift;

    my $values = $self->_read_keyfile(@_);

    unless (defined($values)) {
        return wantarray ? () : undef;
    }

    return wantarray ? @{$values} : $values;
}


sub _read_keyfile
{
    my $self = shift;
    my ($file, $keyname) = @_;
    my $obj = [];

    # Open a file, read/parse the contents of a file
    # line by line and store the results in a scalar.
    my $fh = new IO::File("<$file");

    if (not defined($fh)) {
        $self->error("Failed to open \"$file\": $!", 'crit');
        return undef;
    }

    $self->print("reading key $file", 4);

    while(<$fh>)
    {
        chomp;

        # YAML and JSON key files need to have their first line formatted
        # specifically
        if ($fh->input_line_number == 1 and m/^#?%(?:YAML\s+\d+\.\d+|JSON)/o)
        {
            $obj = $self->_parse_complex_key($fh, $file, $_);
            last;
        }

        #
        # Original style keys
        #

        # Ignore comments and blank lines.
        if (m/^\s*$/o or m/^\s*#/o) {
            next;
        }

        # FIXME  I don't like the capturing of .* below.  Need to refine the
        #        regexp a bit.  The below might work.
        #
        #        elsif (m/^\[%\s*MATCH\s+((?:[^%\]])+)%\]$/o) {
        #
        #        rtilder    Tue May 30 11:34:30 PDT 2006
        #
        # It's a conditional
        elsif (m/^\[%\s*MATCH\s+(.+)\s*%\]$/o) {
            if ($CURRENT_DEPTH == $MAX_NESTING_DEPTH) {
                $self->error('Ruh-roh!  Elbow deep!  Elbow deep!' .
                             "$file, line " . $fh->input_line_number(), 'err');
                return;
            }

            ++$CURRENT_DEPTH;

            if (not $self->_match_criteria($1)) {
                my $accounting = 1;
                # But it doesn't match!  So skip until we get to the closing
                # block so eat the remaining lines in the block
                while (<$fh>) {
                    if (m/^\[%\s*MATCH.*$/o) {
                        ++$accounting;
                    } elsif (m/^\[%\s*END\s*%\]$/o) {
                        # If --$accounting == 0 at this point, we should be at
                        # the end of our parsing block
                        if (not --$accounting) {
                            --$CURRENT_DEPTH;
                            last;
                        }
                    }
                }
            }
            next;
        }
        # It's closing a conditional
        elsif (m/^\[%\s*END\s*%\]$/o) {
            if (--$CURRENT_DEPTH < 0) {
                $self->error('Good job, Bo!  Orphaned [% END %].  ' .
                             "$file, line " . $fh->input_line_number(), 'err');
                return undef;
            }
            next;
        }

        push @{$obj}, $_;
    }

    if ($CURRENT_DEPTH != 0) {
        $self->error("Looks like $file is missing an [% END %] tag.",'err');
        return undef;
    }

    if (defined($fh)) {
        $fh->close();
    }

    return $self->_evaluate_key($keyname, $obj);
}


#
# Reads YAML and JSON style keys
#
sub _parse_complex_key
{
    my $self = shift;
    my $fh   = shift;
    my $file = shift;
    my $method = shift || 'YAML 1.0';

    my $obj = undef;

    unless ($fh->isa('IO::Handle')) {
        $self->error('Invalid object passed to _parse_complex_key: '
                     . ref($fh), 'crit');
        return undef;
    }

    if ($method =~ m/^#?%JSON$/o)
    {
        $obj = JSON::Syck::Load(join('', <$fh>));
    }
    elsif ($method =~ m/^#?%YAML\s+(\d+\.\d+)$/o)
    {
        # Only the YAML v1.0 specification is supported by any YAML parsers
        # as yet.
        if ($1 eq '1.0')
        {
            $obj = YAML::Syck::Load(join('', <$fh>));
        }
        else
        {
            $self->error("Invalid YAML version for $file: $1 != 1.0", 'crit');
        }
    }
    else
    {
        $self->error("Invalid keyfile format in $file: \"$method\"", 'crit');
    }

    unless (defined($obj))
    {
        $self->error("Failed to load $file!", 'crit');
    }

    $fh->close();
    return $obj;
}


sub get_configdir
{
    my $self = shift;
    my $branch = shift;

    # It's perfectly alright if the directory doesn't exist.
    #
    # rtilder    Wed Jul  5 10:52:05 PDT 2006
    unless (-d $branch) {
        return 1;
    }

    my $included = $self->_get_include($branch);

    # It is not alright if the directory exists but is empty
    #
    # rtilder    Wed Jul  5 10:52:05 PDT 2006
    if (not $self->get_values($branch)) {
        $self->error("required directory [$branch] is empty or has errors", 'err');
        return 0;
    }

    # Store the paths we actually managed to descend
    # in the exact order that we did so.
    push(@{$self->{c_descend_order}}, @{$included})
        if (scalar @{$included} > 0);
    push(@{$self->{c_descend_order}}, $branch);

    return 1;
}


# This is where the fun starts!
#
# If we have a reference to a list and the target is a reference to a list
# then we treat it as a an old style config key honouring the old school
# operators.
#
# Otherwise, we don't do anything.  For the moment.
#
sub _evaluate_key
{
    my $self = shift;
    my $keyname = shift;
    my $obj  = shift;

    my $obj_type = ref($obj);

    unless ($obj_type) {
        $self->('Non-reference object passed in for evaluation', 'crit');
        return undef;
    }

    # Let's handle non-array references first for now.
    unless ($obj_type eq 'ARRAY') {
        if (exists($self->{$keyname})) {
            $self->print("$keyname already exists and is a \""
                          . ref($self->{$keyname}) . '".  Replacing with a "'
                          . "$obj_type\"", 0);
        }
        $self->{$keyname} = $obj;

        return $obj;
    }

    # Handle original style keys and their control characters appropriately
    #
    if (exists($self->{$keyname})) {
        my $existing = ref($self->{$keyname});
        unless ($existing eq 'ARRAY') {
            $self->error("Mismatched types for $keyname: It seems that "
                         . "you're trying to use a list on a \""
                         . lc($existing) . '"', 'crit');
            return undef;
        }
    } else {
        # Don't create empty keys
        if ($keyname) {
            $self->{$keyname} = [];
        }
    }

    my @final;

    # Now walk the list looking for control characters and interpreting
    # where necessary.  Otherwise, just append it to the list
    foreach (@{$obj}) {
        # We allow several metacharacters to manipulate
        # pre-existing values in a key.  -regex removes
        # matching values for the key in question.
        if ($keyname && m/^-(.*)$/o) {
            next unless defined @{$self->{$keyname}};

            my $rm_regex = $1;
            @{$self->{$keyname}} = grep(!/$rm_regex/, @{$self->{$keyname}});

            next;
        }

        # If equals (=) is the first and only character of
        # a line, clear the array.  This is used to set
        # absolute values.
        elsif ($keyname && m/^=\s*$/o) {
            delete $self->{$keyname};
            next;
        }

        # If there isn't a control character, just append it.
        #push @{$self->{$keyname}}, $_;
        push @final, $_;
    }

    return \@final;
}


#
# Largely a duplicate of _parse_query above, except less oddly named, I think.
#
# It's duplicated for now because we need to provide backward compatible
# support for conditional includes until we role out generic conditional
# support within keyfiles.  Then we'll yank _parse_query out.
#
# rtilder    Tue May 30 10:40:16 PDT 2006
#
sub _match_criteria
{
    my $self = shift;
    my $criteria = shift;

    # FIXME  The semicolon isn't a necessary distinguisher now, really
    #
    #        rtilder    Tue May 30 14:34:06 PDT 2006
    #
    unless ($criteria =~ m/;\s*/)
    {
        $self->error("Improperly formatted MATCH line: \"$criteria\"", 'err');
        return 0;
    }

    my @querystring = split(/;\s*/, $criteria);

    my %query = map { split(/=/, $_) } @querystring;
    foreach my $k (keys %query)
    {
        unless ($self->getval($k) =~ m/$query{$k}/) {
            return 0;
        }
    }

    return 1;
}


sub get_values
{
    my $self = shift;
    my ($directory) = @_;

    return 0 unless (-d $directory);

    # It's perfectly OK to have an overlay only tree or directory in the
    # descend order that is only a hierachical organizer that doesn't require
    # any config variables be set
    unless (-d catfile($directory, 'config')) {
        return 1;
    }

    $self->print("get_values($directory)", 4);

    # Iterate through each file in a hierarchial endpoint and
    # read the contents to extract values.
    foreach my $keyfile (<${directory}/config/*>)
    {
	# Key names beginning with c_ are reserved for values
	# that are automatically populated by the this module.
	my $keyname = basename($keyfile);
	if ($keyname =~ m/^c_.*/)
	{
	    $self->error("invalid key $keyname in $directory", 'err');
	    next;
	}

	# Read the contents of a file.  Filename is stored
	# as the key, where values are the contents.		
	my $values = $self->_read_keyfile($keyname, $keyfile);

        if (not defined($values)) {
            return 0;
        }

        if (ref($values) eq 'ARRAY') {
            foreach my $value (@{$values}) {
                push(@{$self->{$keyname}}, $value);
            }
        }
    }

    return 1;
}	


1;
