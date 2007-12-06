# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Parser.pm,v 1.1.2.4.2.2 2007/09/11 21:27:58 rtilder Exp $

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
our ($VERSION, @EXPORT_OK, $CURRENT_DEPTH, $MAX_NESTING_DEPTH);

$VERSION = sprintf("%d.%02d", q$Revision: 1.1.2.4.2.2 $ =~ /(\d+)\.(\d+)/);

@EXPORT_OK = qw($MAX_NESTING_DEPTH);

use File::Basename;
use File::Spec::Functions;
use IO::File;
use Spine::Chain;
use Spine::Constants qw(:basic);
use Spine::Exception;
use Spine::Registry;

#
# Complex data types
#
use YAML::Syck;
use JSON::Syck;

#
# Define the exceptions we'll raise.
#
use Spine::Exception qw(MissingFile MissingGroup EvaluationException);

our ($PARSER_FILE);
our ($PARSER_LINE);

sub new
{
    my $class = shift;
    my %args = @_;

    my $registry = new Spine::Registry();
    my $croot = $args{croot} || $args{source}->config_root() || undef;

    unless ($croot) {
        throw Spine::Exception("No configuration root passed to Spine::Parser!");
    }

    my $ctx = $args{context} || $args{hostname};

    my $self = bless { root => $croot,
                       ctx => $ctx,
                       conf => $args{config},
                       chain => $args{chain} }, $class;

    unless (defined($self->{chain})
            and ref($self->{chain}) eq 'Spine::Chain') {
        my $chain = defined($args{chain}) || $self->{conf}->{Parser}->{Chain};
        unless (ref($chain)) {
            my @tmp = split(/(?:\s*,?\s+)/, $chain);
            $chain = \@tmp;
        }

        $self->setup_chain($chain);
    }

    return $self;
}


sub setup_chain
{
    my $self = shift;
    my @chain;
    my $chain = new Spine::Chain;

    if (scalar(@_) == 1 and ref($_[0]) eq 'ARRAY') {
        @chain = @{+shift};
    }
    else {
        @chain = @_;
    }

    my @namespaces = split(/(?:\s*,?\s+)/,
                           $self->{conf}->{Parser}->{Namespaces});

  PARSELET: foreach my $parselet (@chain) {
        my $obj = undef;
        my $class = undef;

      NAMESPACE: foreach my $namespace (('', @namespaces)) {
            my $module = $namespace . '::' . $parselet;

            if (not $namespace) {
                $module = $parselet;
            }

            eval "require $module";

            if ($@) {
                # If it isn't a "can't locate" then log it
                if ($@ !~ m/^Can't\s+locate\s+/) {
                    $self->error("\t\tErrors loading \"$module\": $@");
                }
                next NAMESPACE;
            }

            if ($module->isa('Spine::Parselet')) {
                eval { $obj = $module->new() };

                if ($@) {
                    # FIXME  Need better error reporting
                    print STDERR "SUCK IT UP, BAXTER: $@\n";
                    next NAMESPACE;
                }

                $class = $module;
                last NAMESPACE;
            }
        }

        unless (defined($class)) {
            $self->error("Failed to find or load $parselet!");
            next PARSELET;
        }

        push @{$chain}, $obj;
    }

    if (scalar(@{$chain}) < 1) {
        undef $chain;
        return 0;
    }

    $self->{chain} = $chain;

    return SPINE_SUCCESS;
}


#
# parse() just takes a blob and returns a Spine::Datum on success or undef on
# error.  All additional arguments are considered to be metadata fields
#
sub parse
{
    my $self = shift;
    my $blob = shift;
    my %args;

    unless (defined($blob)) {
        throw Spine::Exception("Undefined value passed to parse()");
    }

    if (ref($blob) eq 'SCALAR') {
        $blob = ${$blob};
    }

    if (ref($_[0]) eq 'HASH') {
        %args = %{+shift};
    }
    else {
        %args = @_;
    }

    if (defined($args{filename})) {
        $PARSER_FILE = $args{filename};
    }

    my $obj = $self->{chain}->walk(\$blob);

    unless (defined($obj)) {
        throw Spine::Exception("Failed to parse, Lord Fontleroy!");
    }

    $PARSER_FILE = undef;

    return $obj;
}


sub PARSER_FILE
{
    return defined($PARSER_FILE) ? $PARSER_FILE : 'unknown';
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
    my ($obj, $template, $complex, $buf) = ([], undef, undef, '');

    # If the file is a relative path and doesn't exist, try an absolute
    unless (-f $file) {
        unless (file_name_is_absolute($file)) {
            $file = catfile($self->{c_croot}, $file);

            unless (-f $file) {
                throw MissingFile("Couldn't find file \"$file\"");
            }
        }
    }

    unless (-r $file) {
        throw MissingFile("Couldn't read file \"$file\"");
    }

    # Open a file, read/parse the contents of a file
    # line by line and store the results in a scalar.
    my $fh = new IO::File("<$file");

    unless (defined($fh)) {
        throw MissingFile("Failed to open \"$file\": $!");
    }

    # I hate this structure so much
    (undef, $PARSER_FILE) = split(/^$self->{c_croot}/, $file, 2);
    $self->print(4, "reading key $file");

  LINE: while(<$fh>)
    {
        $PARSER_LINE = $fh->input_line_number();

        $_ = $self->_convert_lame_to_TT($_);

        # We check this first because we want YAML & JSON files to be
        # templatable as well.  We flag it as a templatized file for a minor
        # performance gain
        if (not defined($template) and m/\[%.+/o)
        {
            $template = 1;
        }

        # YAML and JSON key files need to have their first line formatted
        # specifically
        if ($PARSER_LINE == 1 and m/^#?%(YAML\s+\d+\.\d+|JSON)/o)
        {
            $complex = $1;
            $buf = $_ . join('', <$fh>);
            last LINE;
        }

        # Ignore comments and blank lines.
        if (m/^\s*$/o or m/^\s*#/o) {
            next LINE;
        }

        $buf .= $_;
    }

    $fh->close();

    # Pass it to TT
    if (defined($template)) {
        $buf = $self->_templatize_key($buf);
    }

    # Lastly, we parse the key if it's a complex one
    if (defined($complex)) {
        $obj = $self->_parse_complex_key($buf, $file, $complex);
    }
    else {
        $obj = [split(m/\n/o, $buf)];
    }

    return $self->_evaluate_key($keyname, $obj);
}


sub get_configdir
{
    my $self = shift;
    my $branch = shift;

    # It's perfectly alright if the directory doesn't exist.
    #
    # rtilder    Wed Jul  5 10:52:05 PDT 2006
    unless (-d $branch) {
        return SPINE_SUCCESS;
    }

    # It is not alright if the directory exists but is empty
    #
    # rtilder    Wed Jul  5 10:52:05 PDT 2006
    unless ($self->_get_values($branch) == SPINE_SUCCESS) {
        $self->error("required directory [$branch] has errors", 'err');
        return SPINE_FAILURE;
    }

    # Store the paths we actually managed to descend
    # in the exact order that we did so.
    push(@{$self->{c_descend_order}}, $branch);

    return SPINE_SUCCESS;
}


sub get_config_group
{
    my $self = shift;
    my $group = shift;

    my $group_dir = "$self->{c_group_dir}/$group";

    return $self->get_configdir($group_dir);
}


# This is where the fun starts!
#
# If we have a reference to a list and the target is a reference to a list
# then we treat it as an old style config key honouring the old school
# operators.
#
# Otherwise, we don't do anything.  For the moment.
#
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
            return SPINE_FAILURE;
        }

        if (ref($values) eq 'ARRAY') {
            foreach my $value (@{$values}) {
                push(@{$self->{$keyname}}, $value);
            }
        }
    }

    return 1;
}	


# This is where the fun starts!
#
# If we have a reference to a list and the target is a reference to a list
# then we treat it as an old style config key honouring the old school
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
        throw Spine::Exception('Non-reference object passed in for evaluation');
    }

    # Let's handle non-array references first for now.
    unless ($obj_type eq 'ARRAY') {
        if (exists($self->{$keyname})) {
            $self->print(0, "$keyname already exists and is a \"",
                         ref($self->{$keyname}), '".  Replacing with a "',
                         $obj_type, '"');
        }
        $self->{$keyname} = $obj;

        return $obj;
    }

    # Handle original style keys and their control characters appropriately
    #
    if (exists($self->{$keyname})) {
        my $existing = ref($self->{$keyname});
        unless ($existing eq 'ARRAY') {
            my $msg = "Mismatched types for $keyname: It seems that you're "
                         . "trying to use a list on a \"" . lc($existing) .'"';
            throw Spine::Parser::EvalutationException($msg);
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
        # Ignore comments and blank lines.
        if (m/^\s*$/o or m/^\s*#/o) {
            next;
        }

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


sub error
{
    shift;
    print STDERR 'ERROR: ', @_, "\n";
}


1;
