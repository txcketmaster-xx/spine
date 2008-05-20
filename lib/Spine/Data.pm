# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
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

package Spine::Data;

use strict;

use Cwd;
use Data::Dumper;
use File::Basename;
use File::Spec::Functions;
use IO::Dir;
use IO::File;
use Spine::Constants qw(:basic :plugin);
use Spine::Registry;
use Spine::Util;
use Sys::Syslog;
use Template;
use Template::Exception;
use Template::Stash;
use UNIVERSAL;

use YAML::Syck;
use JSON::Syck;

our $VERSION = sprintf("%d", q$Revision: 1$ =~ /(\d+)/);

our $DEBUG = $ENV{SPINE_DATA_DEBUG} || 0;

our ($DATA_PARSED, $DATA_POPULATED) = (SPINE_NOTRUN, SPINE_NOTRUN);

sub new {
    my $class = shift;
    my %args = @_;

    my $registry = new Spine::Registry();
    my $croot = $args{croot} || $args{source}->config_root() || undef;

    unless ($croot) {
        die "No configuration root passed to Spine::Data!  Badness!";
    }

    my $data_object = bless( { hostname => $args{hostname},
                               c_release => $args{release},
                               c_verbosity => $args{verbosity} || 0,
                               c_version => $args{version} || $::VERSION,
                               c_config => $args{config},
                               c_croot => $croot,
                             }, $class );

    if (not defined($data_object->{c_release}))
    {
        print STDERR "Spine::Data::new(): we require the config release number!";
        return undef;
    }

    # Let's register the hookable points we're going to be running

    # Runtime data discovery.  Basically these are keys that will show up in
    # $c(a.k.a. the "c" object in a template) that aren't parsed out of the
    # configball.  This is stuff like c_is_virtual, c_filer_exports, etc.
    $registry->create_hook_point(qw(DISCOVERY/populate
                                    DISCOVERY/policy-selection));

    # The actual parsing of the configball
    $registry->create_hook_point(qw(PARSE/initialize
                                    PARSE/pre-descent
                                    PARSE/post-descent
                                    PARSE/complete));

    # to be moved out
    $registry->create_hook_point(qw(PARSE/key));

    # XXX Right now, the driver script handles error reporting
    $data_object->_data();

    return $data_object;
}


sub _data
{
    my $self = shift;
    my $rc = SPINE_SUCCESS;

    my $cwd = getcwd();
    chdir($self->{c_croot});

    unless ($self->populate() == SPINE_SUCCESS) {
        $self->{c_failure} = 'Failure to populate: ' . $self->{c_failure};
        $rc = SPINE_FAILURE;
    }

    unless ($rc == SPINE_SUCCESS and $self->parse() == SPINE_SUCCESS) {
        $self->{c_failure} = 'Failure to parse: ' . $self->{c_failure};
        $rc = SPINE_FAILURE;
    }

    chdir($cwd);
    return $rc;
}


sub populate
{
    my $self = shift;
    my $registry = new Spine::Registry();
    my $errors = 0;

    if ($DATA_POPULATED != SPINE_NOTRUN) {
        return $DATA_POPULATED;
    }

    # Some truly basic stuff first.
    $self->{c_label} = 'spine_core';
    $self->{c_start_time} = time();
    $self->{c_ppid} = $$;

    # FIXME  Should these be moved to Spine::Plugin::Overlay?
    $self->{c_tmpdir} = "/tmp/spine." . $self->{c_ppid};
    $self->{c_tmplink} = "/tmp/spine.lastrun";

    # Retrieve "internal" config values nesessary for bootstrapping of
    # discovery and therefore parsing of the tree.
    $self->cprint("retrieving base settings", 3);
    $self->{c_internals_dir} = 'spine_internals';
    $self->_get_values($self->{c_internals_dir});

    my @dir_list = (ref($self->{'spine_local_internals_dirs'}) eq 'ARRAY')
        ? @{$self->{'spine_local_internals_dirs'}}
        : ($self->{'spine_local_internals_dirs'});
    foreach my $dir (@dir_list) {
        $self->_get_values($dir);
    }

    #
    # Begin discovery
    #

    # HOOKME  Discovery: populate
    my $point = $registry->get_hook_point('DISCOVERY/populate');

    my $rc = $point->run_hooks($self);

    # Spine::Registry::HookPoint::run_hooks() returns the number of
    # errors + failures encountered by plugins
    if ($rc != 0) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->{c_failure} = "DISCOVERY/populate failed!";
        return SPINE_FAILURE;
    }

    # We *always* parse the top level config directory
    $self->_get_values($self->{c_croot});

    # HOOKME  Discovery: policy selection
    #
    # Using the data we have gathered, construct the directory paths for
    # our hierarchy.
    #

    # Run our policy selection hooks
    $point = $registry->get_hook_point('DISCOVERY/policy-selection');

    $rc = $point->run_hooks($self);

    unless ($rc == 0) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->{c_failure} = "DISCOVERY/policy-selection failed!";
        return SPINE_FAILURE;
    }

    $DATA_POPULATED = SPINE_SUCCESS;

    return SPINE_SUCCESS;
}

sub parse
{
    my $self = shift;
    my $registry = new Spine::Registry();
    my $errors = 0;

    if ($DATA_PARSED != SPINE_NOTRUN) {
        return $DATA_PARSED;
    }

    # Make sure our discovery phases has been run first since we need a bunch
    # of that info for out parsing.  Most notably the descend order.
    unless ($self->populate() == SPINE_SUCCESS) {
        $self->{c_failure} = "Can't parse, runtime discovery failed somehow!";
        goto parse_failure;
    }

    #
    # Begin parse
    #

    # HOOKME  Parse: parse initialize
    my $point = $registry->get_hook_point('PARSE/initialize');

    my $rc = $point->run_hooks($self);

    if ($rc != 0) {
        $self->{c_failure} = "PARSE/initialize failed!";
        goto parse_failure;
    }

    # Gather config data from the entire hierarchy.
    $self->cprint('descending hierarchy', 3);
    foreach my $branch (@{$self->{c_hierarchy}})
    {
        # HOOKME  Parse: pre-policy descent
        $point = $registry->get_hook_point('PARSE/pre-descent');

        $rc = $point->run_hooks($self);

        if ($rc != 0) {
            $self->{c_failure} = "Failed to run at least one PARSE/pre-descent hook";
            goto parse_failure;
        }

        if (not $self->get_configdir($branch)) {
            return 0;
        }

        # HOOKME  Parse: post-policy descent
        $point = $registry->get_hook_point('PARSE/post-descent');

        $rc = $point->run_hooks($self);

        if ($rc != 0) {
            $self->{c_failure} = "Failed to run at least one PARSE/post-descent hook";
            goto parse_failure;
        }

    }

    # HOOKME  Parse: parse complete
    $point = $registry->get_hook_point('PARSE/complete');

    $rc = $point->run_hooks($self);

    if ($rc != 0) {
        $self->{c_failure} = "Failed to run at least one PARSE/complete hook";
        goto parse_failure;
    }

    $self->print(1, "parse complete");

    return SPINE_SUCCESS;

 parse_failure:
    $DATA_PARSED = SPINE_FAILURE;
    return SPINE_FAILURE;
}


#
# Public interface for get_values.  Very possibly unnecessary at the moment.
#
sub get_values
{
    return _get_values(@_);
}


sub _get_values
{
    my $self = shift;
    my $directory = shift;
    my $keys_dir = $self->getval_last('config_keys_dir') || 'config';

    $directory = catdir($directory, $keys_dir);

    # It's perfectly OK to have an overlay-only tree or directory in the
    # descend order that is only a hierachical organizer that doesn't require
    # any config variables be set
    unless (-d $directory) {
            return SPINE_SUCCESS;
    }

    # Iterate through each file in a hierarchial endpoint and
    # read the contents to extract values.
    my $dir = new IO::Dir($directory);

    unless (defined($dir)) {
        $self->error("_get_values(): failed to open $directory: $!", 'crit');
        return SPINE_FAILURE;
    }

    my @files = $dir->read();
    $dir->close();

    foreach my $keyfile (sort(@files))
    {
        # Key names beginning with c_ are reserved for values
        # that are automatically populated by the this module.
        my $keyname = basename($keyfile);
            if ($keyname eq '.' or $keyname eq '..') {
                next;
            }

        if ($keyname =~ m/(?:(?:^(?:\.|c_\#).*)|(?:.*(?:~|\#)$))/) {
            $self->error("ignoring $directory/$keyname because of lame"
                             . ' file name');
            next;
        }

    
        # Read the contents of a file.  Filename is stored
        # as the key, where value(s) are the contents.      
        my $value = $self->_read_keyfile(catfile($directory, $keyfile),
                                              $keyname);
    
        if (not defined($value)) {
            return SPINE_FAILURE;
        }
    
        if (ref($value) eq 'ARRAY') {
            push(@{$self->{$keyname}}, @{$value});
        } else {
            $self->{$keyname} = $value;
        }

    }

    return SPINE_SUCCESS;
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
    my ($obj, $template, $buf) = ([], undef, undef, '');

    # If the file is a relative path and doesn't exist, try an absolute
    unless (-f $file) {
        unless (file_name_is_absolute($file)) {
            $file = catfile($self->{c_croot}, $file);

            unless (-f $file) {
                $self->error("Couldn't find file \"$file\"", 'crit');
                return undef;
            }
        }
    }

    unless (-r $file) {
        $self->error("Can't read file \"$file\"", 'crit');
        return undef;
    }

    # Open a file, read/parse the contents of a file
    # line by line and store the results in a scalar.
    my $fh = new IO::File("<$file");

    unless (defined($fh)) {
        $self->error("Failed to open \"$file\": $!", 'crit');
        return undef;
    }

    $self->print(4, "reading key $file");

    my $first_line = undef;
    while(<$fh>)
    {
        # FIXME this should be removed some time
        $_ = $self->_convert_lame_to_TT($_);

        # We flag it as a templatized file for a minor
        # performance gain, XXX I think it might be nice to scrap this?
        if (not defined($template) and m/\[%.+/o)
        {
            $template = 1;
        }

        $buf .= $_;
    }

    $fh->close();

    # parse the key
    # HOOKME Parselet expansion
    my $registry = new Spine::Registry;
    my $point = $registry->get_hook_point('PARSE/key');
    $obj = { obj => $buf,
             file => $file,
             keyname => $keyname,
             template => $template};
    my $rc = $point->run_hooks_until(PLUGIN_STOP, $self, $obj);
 
    # TODO Report Errors
    unless ($rc == PLUGIN_FINAL) {
        return undef;
    }
    return $obj->{obj};
}


#
# _convert_lame_to_TT tweaks the lame ass TT-like MATCH syntax I created with
# actual TT logic so that it can all be processed by TT directly.
#
sub _convert_lame_to_TT
{
    my $self = shift;
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
    if (not $self->_get_values($branch)) {
        $self->error("required directory [$branch] is empty or has errors",
                     'err');
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

    my $group_dir = catdir($self->getval_last('include_dir'), $group);

    return $self->get_configdir($group_dir);
}


sub getval
{
    my $self = shift;
    my $key = shift;
    $self->print(4, "getval -> $key");
    return undef unless (exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return  $self->{$key}[0];
    }
    else
    {
	return $self->{$key};
    }
}


sub getval_last {
    my $self = shift;
    my $key = shift;
    $self->print(4, "getval -> $key");
    return undef unless (exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return  $self->{$key}[-1];
    }
    else
    {
	return $self->{$key};
    }
}


sub getvals
{
    my $self = shift;
    my $key = shift;
    $self->print(4, "getvals -> $key");
    return undef unless ($key && exists $self->{$key});

    if ((ref $self->{$key}) eq "ARRAY")
    {
	return $self->{$key};
    }
    else
    {
	return [$self->{$key}];
    }
}


sub getvals_as_hash
{
    my $self = shift;
    my $key = shift;

    $self->print(4, "getval_as_hash -> $key");

    return undef unless($key && exists($self->{key}));

    if (ref($self->{$key}) eq 'ARRAY')
    {
        # Make sure it's an array with an even number of elements(greater than
        # zero)
        my $oe = scalar(@{$self->{$key}});

        if ($oe and not ($oe % 2))
        {
            my %vals_as_hash = @{$self->{$key}};
            return \%vals_as_hash;
        }
    }

    return undef;
}


sub getvals_by_keyname
{
    my $self          = shift;
    my $key_re        = shift || undef;
    my @matching_vals = ();

    $self->print(4, "getvals_by_keyname -> $key_re");

    foreach my $key (keys(%{$self})) {
	if ($key =~ m/$key_re/o) {
	    push @matching_vals, $self->{key};
	}
    }

    # Sorted for minimal changes in diffs of templates
    @matching_vals = sort @matching_vals;
    return (scalar @matching_vals > 0) ? \@matching_vals : undef;
}


sub search
{
    my $self = shift;
    my $regex = shift;

    my @keys = grep(/$regex/, keys %{$self});
    return \@keys;
}


sub set_label
{
    my $self = shift;
    my $label = shift;

    if ($label)
    {
	$self->{c_label} = $label;
	return 1;
    }

    return 0;
}


#
# This method checks its call stack to make sure that it isn't being called
# from anywhere inside Template::Toolkit and prevents any template from
# changing any "c_*" keys.
#
# FIXME  This should really happen for all the variables.  We should probably
#        have a Spine::Data::TemplateProxy class or similar that prevents a
#        template from modifying any data in it via TIE.  Shouldn't be too
#        difficult, come to think of it.
#
sub set
{
    my $self = shift;
    my $key = shift;
    my $in_template = 0;

    # We should never get a stack deeper than 30
    foreach my $i (1 .. 30) {
        my @frame = caller($i);

        if ($frame[3] =~ m/^Template/) {
            $in_template = 1;
            last;
        }
    }

    # FIXME   This is pretty lame way to differentiate which context the
    #         template is running in.
    #
    # This is ok as long as we're in a key template instance but it's not ok
    # if we're in an overlay template instance.  Ain't life grand?
    if ($in_template and not defined($Spine::Plugin::Template::KEYTT)) {
        $self->error("We've got an overlay template that's trying to call "
                     . "Spine::Data::set($key).  This is bad.");
        die (Template::Exception->new('Spine::Data::set()',
                                      'Overlay template trying to call ' .
                                      "Spine::Data::set($key).  Bad template"));
    }

    if (exists($self->{$key})) {
        push @{ $self->{$key} }, @_;
    }
    #
    # If it's a reference of any kind, don't make it an array.  This permits
    # plugins to call $c->set('c_my_plugin', $my_plugin_obj).  ONLY do this if
    # there's only one argument passed in.  Otherwise, push them in as an array
    #
    # This bit me in the ass with the auth plugin's _grep_hash_element() method
    # while it spewed "Out of memory" to the console.
    #
    # rtilder    Tue Dec 19 15:52:52 PST 2006
    elsif (ref($_[0]) and scalar(@_) == 1) {
        $self->{$key} = $_[0];
    }
    else {
        $self->{$key} = [ @_ ];
    }

    # TT gets awfully confused by return values
    $in_template ? return : return 1;
}


sub check_exec
{
    my $self = shift;
    foreach my $binary (@_)
    {
	return 0 unless (defined $binary);
	$self->print(4, "checking binary $binary");
	if ( ! -x "$binary" )
	{
	    $self->error("binary $binary is unavailable: $!", "crit");
	    return 0;
 	}
    }
    return 1;
}


sub cprint
{
    my $self = shift;
    my ($msg, $level) = @_;
    my $log_to_syslog = shift || 1;

    if ($level <= $self->{c_verbosity})
    {
	print $self->{c_label}, ": $msg\n";
	syslog("info", "spine: $msg")
            if ( not $self->{c_dryrun} or $log_to_syslog );
    }
}


sub print
{
    my $self = shift;
    my $lvl = shift || 0;

    if ($lvl <= $self->{c_verbosity})
    {
#	print $self->{c_label}, '[', join('::', caller()), ']: ', @_, "\n";
	print $self->{c_label}, ': ', @_, "\n";
    }
}


sub log
{
    my $self = shift;
    my $msg = shift;

    if (not $self->{c_dryrun}) {
        syslog('info', "spine: $msg");
    }
}


sub error
{
    my $self = shift;
    my ($msg, $level) = @_;
    $level = 'err' unless ($level =~ m/
			       alert|crit|debug|emerg|err|error|
			       info|notice|panic|warning|warn
			       /xi );
    $msg =~ tr/\n/ -- /;

    unless ($self->{c_verbosity} == -1)
    {
	print STDERR $self->{c_label} . ": \[$level\] $msg\n";
    }

    syslog("$level", "spine: $msg")
        unless $self->{c_dryrun};
    push(@{$self->{c_errors}}, $msg);
}


sub util
{
    my $self = shift;
    my $util = shift;

    no strict 'refs';
    my $return = &{"Spine::Util::" . $util}(@_);
    use strict 'refs';
    if (not defined $return)
    {
        my $pargs = join(" ", @_);
	$self->error("$util failed to execute with args: $pargs", 'crit');
    }
    return $return;
}


sub get_release
{
    return (shift)->{c_release};
}


sub debug
{
    my $lvl = shift;

    if ($DEBUG >= $lvl) {
        print STDERR "DATA DEBUG($lvl): ", @_, "\n";
    }
}


1;
