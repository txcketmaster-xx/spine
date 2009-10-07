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

use strict;

package Spine::Plugin::Templates;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);

our ($VERSION, $DESCRIPTION, $MODULE, $MARKERS, $QUICK);

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Plugin for interperolating templates.";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { PREPARE => [ { name => 'quick_template',
                                      code => \&quick_template } ],
                       EMIT => [ { name => 'process_templates',
                                   code => \&process_templates } ],
                      'PARSE/key' => [ { name => "TT",
                                         code => \&_templatize_key,
                                         # this is a markup parselet
                                         provides => ['markup',
                                                      'processed_template'],
                                        } ]
                     },
            cmdline => { _prefix => 'template',
                         options => {
                                     'markers!' => \$MARKERS,
                                     'quick|quick!' => \$QUICK,
                                    }
                       }
          };


use File::Basename;
use File::Find;
use File::stat;
use Fcntl qw(:mode);
use Template;
use Template::Stash;
use File::Spec::Functions;

my $TT = undef;
our $KEYTT = undef;

our (@TEMPLATES, @IGNORE, $TMPDIR);

# XXX: depreciated as of 2.2
# XXX: to be removed in 2.3
# converts the old TT-like MATCH to
# actual TT logic so that it can all be processed by TT directly.
# This is based on the origianl _convert_lame_to_TT but works on a multi
# line scalar not an array element.
sub _convert_to_TT {
    my $data = shift;
    my $legacy = 0;
    while ( $data->{obj} =~ m/(\[%(\s*)(IF|MATCH|ELSIF)\s+(.+?)%\])/sog ) {
        my $new_pos = pos($data->{obj});  # This is the pos of the end of match
        my $data_length = length($1);

        my $new = "[\%$2" . (( $3 eq 'MATCH' or $3 eq 'IF' ) ? 'IF' : 'ELSIF');
        my $criteria = $4;
        
        # If there isn't a semi-colon, it's not one of ours
        unless ( $criteria =~ qr/;\s*/ ) {
           next;
        }
                
        my @conditions;
        foreach my $condition (split( /;\s*/, $criteria )) {
            push @conditions, (sprintf("c.%s.search('%s')",
                                       split( /=/, $condition)));
        }

        $new .= ' ' . join( ' AND ', @conditions ) . " \%]";
                
        # Replace within the string
        substr($data->{obj}, ($new_pos - $data_length), $data_length, $new);
        # Set the position for the next iteration to after out insert (magic)
        pos($data->{obj}) = ($new_pos - $data_length) + length($new); 
        # Take note that this is a legacy key
        $legacy = 1;
    }
    
    return $legacy;
}


sub process_templates
{
    my $c = shift;
    my $rval = 0;
    my $tmpdir = $c->getval('c_tmpdir');
    my $ignore = $c->getvals("templates_ignore");

    $TMPDIR = $tmpdir;
    @TEMPLATES = ();

    unless (-d $tmpdir)
    {
        $c->error("temp directory [$tmpdir] does not exist", 'crit');
        return PLUGIN_FATAL;
    }

    # Pre-compile our regular expressions for templates to ignore
    if (defined($ignore) and scalar(@IGNORE) == 0) {
        @IGNORE = map qr/$_/o, @{$ignore};
    }
    undef $ignore;

    # Find our templates.  templates_ignore checking is done in find_templates
    find({ follow => 0, no_chdir => 1, wanted => \&find_templates }, $tmpdir);

    @TEMPLATES = sort @TEMPLATES;

    $c->print(4, 'Templates: ', @TEMPLATES);

    foreach my $template (@TEMPLATES)
    {
        if (process_template($c, $template) == PLUGIN_ERROR)
        {
            $c->error("error processing $template", "err");
            $rval++;
        }
    }

    return $rval ? PLUGIN_ERROR : PLUGIN_SUCCESS;
}


# Note that we do a regular stat, not an lstat here because we want to permit
# following symlinks as necessary.
#
# rtilder    Thu May  3 11:09:00 PDT 2007
#
sub find_templates
{
    my $fname = $File::Find::name;
    my $fstat = stat($fname);

    my (undef, $dest) = split(/^$TMPDIR/, $fname);

    if ($dest =~ m/^$/)
    {
        return;
    }

    my (undef, undef, $suffix) = fileparse($fname, '.tt');

    # Doesn't end in .tt?  We don't care.
    unless ($suffix)
    {
        return;
    }

    # If it's a symlink but the target doesn't exist, then the stat() call
    # above will return undefined.
    if (defined($fstat) and S_ISREG($fstat->mode))
    {
        if (check_ignore($dest) == PLUGIN_SUCCESS)
        {
            unlink($fname);
        }
        else
        {
            push @TEMPLATES, $fname;
        }
    }
}


sub check_ignore
{
   my $path = shift;

   foreach my $regex (@IGNORE)
   {
	return PLUGIN_SUCCESS if ($path =~ m@$regex@);
   }

   return PLUGIN_ERROR;
}


sub process_template
{
    my ($c, $template, $output) = @_;
    # This makes Spine::Data avaliable as 'c' within templates
    # as well as allowing the user to stop template processing
    # if they decide the template is not needed (skip_template)
    my $ttdata = {c => $c,
                  skip_template => sub { die "__SKIP__TEMPLATE__\n" }};
    my $destdir;

    # Create our template processing instance
    unless (defined($TT)) {

        #
        # NOTE!!
        #
        # Do *NOT* under any circumstances add INTERPOLATE to the TT object
        # instantiation.  It blows up to all hell in all kinds of file formats,
        # most notably /etc/bashrc.tt
        #
        # rtilder    Thu Jan 11 12:04:08 PST 2007
        #
        $TT = Template->new( { INCLUDE_PATH => $destdir,
                               EVAL_PERL           => 1,
                               PRE_CHOMP           => 1,
                               ABSOLUTE            => 1,
                               RECURSION           => 1,
                               RELATIVE            => 1,
                             } );
    }

    # If $output isn't a ref to a scalar then we output to a the template's
    # full path name minus the ".tt" extension.
    unless (defined($output) and ref($output) eq 'SCALAR') {
        # Seems like a lot of work to get the full path and filename minus the
        # '.tt' extension, but it should be 100% portable.
        $destdir = dirname($template);
        ($output, undef, undef) = fileparse($template, '.tt');
        $output = catfile($destdir, $output);
    }

    $c->cprint("processing template $template", 3);

    unless (defined($TT->process($template, $ttdata, $output)))
    {
        # If the user has decided they don't want the template
        # from within the template we unlink (skip_template)
        if ($TT->error() =~ m/__SKIP__TEMPLATE__/) {
            $c->cprint("Template has requested to be skipped, $template", 3);
            unlink($template);
            return PLUGIN_SUCCESS;
        }
        
        # If we encounter an error we want to abort the current template
        # but keep processing, so log the error, remove the template 
        # from the overlay, and return PLUGIN_ERROR to move on instead
        # of PLUGIN_FATAL and blowing up.
        $c->error('could not process template: ' . $TT->error(), "err");
        unlink($template);
        return PLUGIN_ERROR;
    }

    unless (ref($output) eq 'SCALAR')
    {
        my $sb = stat($template);

	# For some strange reason TT does not apply the expected
	# permissions and ownership to the destination file.
	chmod $sb->mode, $output;
	chown $sb->uid, $sb->gid, $output;
        unlink($template);
    }

    return PLUGIN_SUCCESS;
}


sub quick_template
{
    my $c = shift;

    unless ($QUICK) {
        return PLUGIN_SUCCESS;
    }

    # Make sure we don't save state
    $::SAVE_STATE = 0;

    foreach my $template (@ARGV) {
        my $output;

        unless (-f $template) {
            print "No such file \"$template\"\n";
            next;
        }

        unless (process_template($c, $template, \$output)) {
            $c->error("Failed to process template", 'err');
            return PLUGIN_EXIT;
        }

        my $file_short = basename($template);
        print "[ Start: $file_short ]\n" if ($MARKERS);
        print $output;
        print "[ End: $file_short ]\n" if ($MARKERS);
    }

    return PLUGIN_EXIT;
}


#
# Provides the same functionality as
# http://template-toolkit.org/docs/manual/VMethods.html#method_search but on
# a list of scalars
#
sub _TT_list_search
{
    my ($list, $pattern) = @_;
    my $rc = 0;

    return undef unless defined($list) and defined($pattern);

    foreach my $str (@{$list}) {
        $rc++ if $str =~ qr/$pattern/o;
    }

    return $rc;
}


#
# Throws a TT exception for ease of tracking
#
sub _TT_hash_search
{
    die (Template::Exception->new('Spine::Data',
                                  'Attempting to call search() on a complex config key'));
}


sub _templatize_key
{
    my ($c, $data) = @_;
    my $ttdata = { c => $c };


    #  $output = \$output would be a cicular ref (as expected)
    #  so we have to use another var.
    my $tmp_var = "";
    my $output = \$tmp_var;

    # TODO optermize again
    # Has templatization been detected?
    #unless (exists $data->{template}) {
    #    return PLUGIN_SUCCESS;
    #}

    # Skip refs, only scalars
    if (ref($data->{obj})) {
        return PLUGIN_SUCCESS;
    }
    
    # XXX: remove in version 2.3
    if (_convert_to_TT($data)) {
        $c->error("$data->{source} uses depreciated flow control syntax",
                  "warning");
    }

    unless (defined($KEYTT)) {
        Template::Stash->define_vmethod('list', 'search', \&_TT_list_search);
        Template::Stash->define_vmethod('hash', 'search', \&_TT_hash_search);
        $KEYTT = new Template( { CACHE_SIZE => 0 } );
    }

    my $template = $data->{obj};
    # Note the $template is passed in as a reference to make sure it isn't
    # mistaken for a filename
    unless (defined($KEYTT->process(\$data->{obj}, $ttdata, $output))) {
        # FIXME, implement error reporting
        $c->error("could not process templatized key ($data->{source}): "
                     . $KEYTT->error(), 'err');
        return PLUGIN_ERROR;
    }
    
    $data->{obj} = ${$output};
    return PLUGIN_SUCCESS;
}



1;
