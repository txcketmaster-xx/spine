#!/usr/bin/python

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

import ConfigParser
import getopt
import pprint
import os
import os.path
import signal
import string
import sys
import syslog
import tempfile
import time

# For simplicity's sake.  I hate exec'ing and parsing
from svn import core, client, delta, fs, repos
import libsvn

class PublisherError(Exception):
    def __init__(self, msg):
        self.msg = msg

class PublisherSVNError(PublisherError):
    pass

class PublisherCheckoutError(PublisherSVNError):
    pass

class PublisherBranchHarvesterError(PublisherSVNError):
    pass

class PublisherRestoreError(PublisherError):
    pass

class PublisherFSBallError(PublisherError):
    pass

class PublisherCleanupError(PublisherError):
    pass

class PublisherPublishingError(PublisherError):
    pass

SKIPDIRS = ('.svn', '.', '..')
#OVERLAYDIRS = ('overlay', 'class_overlay')
OVERLAYDIRS = ('overlay', )
TMWEBUID = 1141
TMWEBGID = 1014
SPECIAL_TYPES = ('block', 'character', 'fifo')

DEBUG = 0
NO_PUBLISH = 0
NO_CLEANUP = 0
FIFOPATH = '/var/run/cramfs-publisher.fifo'


def debug(level, *msgs):
    if (DEBUG >= level):
        for msg in msgs:
            print "DEBUG: %s" % msg


class SpineCRAMFSPublisher:
    def __init__(self, pool, config, fifo_path):
        self.pool = pool
        self.config = config
        self.fifo_path = fifo_path

        self.orig_working_dir = os.curdir
        self.pools = {}
        self.editor_results = {}
        self.branches = []
        self.node_props = {}
        self.fsballs = {}

        while True:
            # Open the FIFO for reading
            try:
                fifo = open(self.fifo_path, 'r')
            except Exception, err:
                raise PublisherError("Couldn't open FIFO for reading: %s" % err)

            # Siphon the queue
            lines = fifo.readlines()

            # Close the FIFO because FIFOs fscking *SUCK*
            fifo.close()

            for line in lines:
                repo_path, release = line.strip().split()

                release        = int(release)
                self.repo_path = repo_path
                self.release   = release

                l = 'Processing release number %d from %s' % (release, repo_path)
                syslog.syslog(l)

                #
                # We have to fork here because Subversion doesn't seem to be
                # very good about providing methods for closing or destroying 
                #
                try:
                    pid = os.fork()

                    if pid == 0:
                        rc = 0
                        try:
                            self.run()
                        except PublisherError, err:
                            l = "Failed to publish release number %d from %s: %s" % (release, repo_path, err.msg)
                            rc = 1
                        else:
                            l = "Published %d from %s successfully" % (release,
                                                                       repo_path)

                        syslog.syslog(l)
                        sys.exit(rc)
                    else:
                        rpid, rc = os.waitpid(pid, 0)

                        if rpid != pid:
                            syslog.syslog("waitpid(%d, 0) returned the wrong pid(%d)" % (pid, rpid))

                        if (rc >> 8) != 0:
                            syslog.syslog("Worker process %d failed!" % pid)
                            syslog.syslog("Failed to publish release %d" % release)

                except OSError, err:
                    l = "Failed to fork child for release %d: %s" % (release,
                                                                     err)
                    syslog.syslog(l)
                    sys.exit(1)


    def run(self):
        # Set up our repo object
        repos_ptr = repos.svn_repos_open(self.repo_path, self.pool)

        # So that we can create our fs object
        self.fs_ptr = repos.svn_repos_fs(repos_ptr)

        if self.release is None:
            self.release = fs.youngest_rev(self.fs_ptr, pool)

        # We should now have every thing we need to query against a repo

        debug(1, "Getting branch list...")

        # Find out which dirs were affected
        self.get_branches(self.editor_results)

        debug(4, "Mapping branchs to config stanzas...")

        # Map those to appropriate config stanzas
        for path in self.editor_results.keys():

            debug(7, "Modified files in \"%s\"" % path)

            stanza = self.get_stanza(path)

            if stanza is None:
                raise PublisherError("Couldn't determine stanza for affected "
                                     "directory: %s" % path)

            branch_path = self.config.get(stanza, 'path')
            branch_type = self.config.get(stanza, 'type')

            if branch_type == 'trunk':
                if not (branch_path in self.branches):
                    self.branches.append(branch_path)
                    continue
            elif branch_type == 'branch':
                # Get the exact path of the branch
                # Yes, +1, We want to include a trailing slash
                baselen = len(branch_path) + 1
                b = path[baselen:]
                blen = b.index(os.sep)
                real_branch = path[:baselen + blen]
                if not (real_branch in self.branches):
                    self.branches.append(real_branch)
                    continue

        # Not our bag
        if len(self.branches) <= 0:
            return

        debug(5, "Affected branches are: %s" % self.branches)

        debug(1, "Checking out repo...")

        # Checkout the release
        self.checkout_release(self.release)

        debug(1, "Restoring properties to overlays in affected branches...")

        # Walk the tree and apply the various spine:* properties and delete
        # all '.svn/' directories from the tree
        self.restore_branches(self.tempdir, self.branches)

        debug(1, "Building CRAMFS balls...")

        # Build CRAMFS balls
        for branch in self.branches:
            self.mkfsball(self.tempdir, branch)

        # PUBLISH!
        if not NO_PUBLISH:
            debug(1, "Publishing...")
            for branch in self.branches:
                self.publish(branch)

        # Clean up our client
        if not NO_CLEANUP:
            debug(1, "Cleaning up...")
            self.cleanup()


    def get_stanza(self, path):
        for stanza in self.config.sections():
            if stanza == 'repo':
                continue

            try:
                string.index(path, self.config.get(stanza, 'path'))
            except ValueError:
                pass
            else:
                return stanza

        return None


    # Originally cribbed from subversion-1.1.1/tools/examples/svnlook.py
    def get_branches(self, results_target):
        # set up a pool for our branch sucking
        self.pools['branches'] = pool = core.svn_pool_create(self.pool)

        # get the current root
        try:
            root = fs.revision_root(self.fs_ptr, self.release, pool)

            # We need to diff against the previous release
            base_root = fs.revision_root(self.fs_ptr, self.release - 1,
                                         self.pool)
        except libsvn._core.SubversionException, err:
            raise PublisherBranchHarvesterError("%s" % err) 

        editor = ChangedBranchHarvester(results_target)

        e_ptr, e_baton = delta.make_editor(editor, self.pool)

        def authz_cb(root, path, pool):
            return 1

        repos.svn_repos_dir_delta(base_root, '', '', root, '',
                                  e_ptr, e_baton, authz_cb, 0, 1, 0, 0,
                                  self.pool)


    def create_client(self, pool = None):
        # set up our local pool, if necessary
        if pool is None:
            pool = core.svn_pool_create(self.pool)

        client_store = client.svn_client_create_context(pool)

        # Set the default config we're going to use
        client_store.config = core.svn_config_get_config(None, pool)
        client_store.auth_baton = core.svn_auth_open([client.svn_client_get_simple_provider(pool)], pool)

        return client_store


    def create_revision(self, release):
        revision = core.svn_opt_revision_t()
        revision.kind = core.svn_opt_revision_number
        revision.value.number = release

        return revision


    def checkout_release(self, release):
        # Set up our temp dir
        self.tempdir = tempfile.mktemp()

        try:
            os.mkdir(self.tempdir, 0770)
        except OSError, err:
            raise PublisherError("Couldn't make temp directory: %s" % err)

        debug(3, "Target dir for checkout is: %s" % self.tempdir)

        self.repo_url = self.config.get('repo', 'url')

        debug(3, "URL for repo is: %s" % self.repo_url)

        # Create our client instance
        self.co_client = self.create_client(self.pool)

        # Set up our revision object
        self.revision_obj = self.create_revision(release)

        debug(4, "Checking out revision %d" % release)

        # Now check out
        actual_release = client.svn_client_checkout(self.repo_url,
                                                    self.tempdir,
                                                    self.revision_obj,
                                                    True,
                                                    self.co_client,
                                                    self.pool)

        debug(3, "Actual release is: %s" % actual_release)
        return actual_release


    def find_in_tree(self, path, cb):
        debug(9, "  find_in_tree(%s, %s)" % (path, cb))

        overlays = []

        # Make sure we check the path as passed in.
        debug(10, "      callback on %s" % path)
        if cb(path, ''):
            overlays.append(path)

        for entry in os.listdir(path):
            fullpath = os.path.join(path, entry)

            debug(10, "      callback on %s" % fullpath)

            if cb(path, entry):
                overlays.append(fullpath)

            if os.path.isdir(fullpath):
                debug(10, "      drilling down %s" % fullpath)
                overlays.extend(self.find_in_tree(fullpath, cb))

        debug(9, "overlays = %s" % overlays)
        return overlays


    def restore_branches(self, path, branches):
        # Callback passed to find_in_tree for finding .svn dirs
        def _find_svn_dirs_cb(dirname, entry):
            debug(9, "          _find_svn_dirs_cb(%s, %s)" % (dirname, entry))

            if entry == '.svn':
                return True

            return False
            

        os.chdir(path)

        for branch in branches:
            #
            # FIRST!
            #
            # We grab the *entire* proplist for the entire affected branches
            #

            # svn.client.svn_client_proplist() returns a list of tuples
            # structured like:
            #
            # [ ('node name',
            #         {dict with  <'property name': property value> mapping} ),
            #   ... ]
            #
            # The third argument is whether or not to recurse the directory
            # tree for all versioned elements under "node".
            import libsvn
            try:
                # Generate one big list of files to keep the hits on the repo
                # server to a minimum
                node_props = client.svn_client_proplist(branch,
                                                        self.revision_obj,
                                                        True, self.co_client,
                                                        self.pool)
            except libsvn._core.SubversionException, err:
                debug(4, "Repo communication problems: %s" % err)
                raise PublisherRestoreError("This sucks!")

            debug(8, "node_props ==\n%s" % pprint.pformat(node_props))

            try:
                self.restore_tree(branch, node_props)
            except PublisherRestoreError, error:
                syslog.syslog("Oh, dear: %s" % error.msg)

            # Create "Release" file"
            try:
                Release = open('%s/Release' % branch, 'w')
                Release.write("%d\n" % self.release)
                Release.close()
            except Exception, err:
                raise PublisherError("Couldn't create Release file: %s" % err)


        debug(3, "Trimming all .svn dirs...")

        svndirs = self.find_in_tree(path, _find_svn_dirs_cb)

        # This sucks but Python filesystem operations just suck, really
        count = 0
        while count < len(svndirs):
            foo = svndirs[count:count + 200]
            cmd = "/bin/rm -rf "

            for entry in foo:
                cmd += "%s " % entry

            debug(7, "Command is: %s" % cmd)

            try:
                if os.system(cmd):
                    raise PublisherRestoreError("Command failed: %s" % cmd)

                count += 200
            except OSError, err:
                raise PublisherRestoreError("Failed to remove \"%s\": %s" \
                                            % (path, err))

        os.chdir(self.orig_working_dir)

        return True


    def restore_tree(self, path, node_props):
        debug(3, "Path is: %s" % path)

        # Walk the list and process
        failures = 0
        count = len(node_props)
        for node in node_props:
            # + 1 assumes the URL specified in the config doesn't end in a
            # trailing slash
            start = len(self.repo_url) + 1

            # If the URL does end in a trailing slash, we don't add one
            if self.repo_url[-1] == '/':
               start = len(self.repo_url)

            # node[0] is the full URL to the node
            filepath = node[0][start:]
            try:
                self.restore_props(filepath, node[1])
            except PublisherRestoreError, error:
                failures += 1
                syslog.syslog("Oh, dear: %s" % error.msg)

        debug(4, "  %d nodes, %d failures, %d successful" % (count, failures,
                                                             count - failures))

        if failures > 0:
            return False

        return True


    def parse_perms(self, perms):
        # Get the perms and convert them to a usable int.  There's probably
        # a library function that'll do this that I'm unaware of
        o = 0
        i = len(perms)
        for j in perms:
            o += int(j) << ((i - 1) * 3)
            i -= 1

        return o


    def force_overlay_dir(self, path):
        basename = os.path.basename(path)

        try:
            if basename == 'overlay':
                os.chown(path, 0, 0)
            elif basename == 'class_overlay':
                os.chown(path, TMWEBUID, TMWEBGID)
            os.chmod(path, 0755)
        except OSError, foo:
            syslog.syslog("Failed to set default properties on overlay dir \"%s\": %s" % (path, foo))
            return


    def restore_special_file(self, path, props):
        if not (str(props['spine:filetype']) in SPECIAL_TYPES):
            debug(4, "Types are: %s" % pprint.pformat(SPECIAL_TYPES))
            raise PublisherRestoreError("File type not handled for \"%s\": "
                                        "\"%s\"" % (path,
                                                props['spine:filetype']))

        try:
            os.unlink(path)
        except OSError, error:
            raise PublisherRestoreError("Failed to unlink \"%s\"" % path)

        dev = None
        ftype = props['spine:filetype']

        if ftype == 'fifo':
            ftype = 'p'
        else:
            if ftype == 'block':
                ftype = 'b'
            elif ftype == 'character':
                ftype = 'c'

##        try:
##            # Python < 2.3 doesn't have mknod or makedev.  Rock on!
##            # Morons.
##            dev = os.makedev(int(props['spine:majordev']),
##                             int(props['spine:minordev']))
##            except OSError, error:
##                raise PublisherRestoreError("Couldn't create special file"
##                                            " for \"%s\": %s" % (path,
##                                                                 error))

##        mode = self.parse_perms(props['spine:perms'])

        try:
##            if major and minor and dev:
##                os.mknod(path, mode | ftype, dev)
##            else:
##                # It's a FIFO
##                os.mknod(path, mode | ftype)
            cmd = "/bin/mknod --mode=%s %s %s %s %s" \
                  % (str(props['spine:perms']),
                     path, ftype,
                     str(props['spine:majordev']),
                     str(props['spine:minordev']))
            
            debug(6, "Running command: \"%s\"" % cmd)
            
            if os.system(cmd):
                raise PublisherRestoreError("Command failed: \"%s\"" % cmd)
        except OSError, error:
            raise PublisherRestoreError("Failed to create special file \"%s\":"
                                        " %s" % (path, error))

        return

    def restore_props(self, path, props):
        islink = os.path.islink(path)

        if string.find(path, 'overlay') == -1:
            return  # It's a non-overlay file so we don't care

        if not os.path.exists(path) and not islink:
            raise PublisherRestoreError("%s doesn't exist!" % path)

        # Every entry in an overlay directory tree must have permissions and
        # ownership properties set
        if not props.has_key('spine:ugid'):
            raise PublisherRestoreError("%s doesn't have ownership property"
                                        % path)
        
        if not props.has_key('spine:perms'):
            raise PublisherRestoreError("%s doesn't have permissions property"
                                        % path)
        
        # Special settings for overlay dirs
        if os.path.isdir(path) and (os.path.basename(path) in OVERLAYDIRS):
            self.force_overlay_dir(path)
            return

        # Handle device files' special properties, perms and ownership are
        # handled below by the "regular files" block below
        if props.has_key('spine:filetype'):
            self.restore_special_file(path, props)

        perms = self.parse_perms(props['spine:perms'])

        owner = str(props['spine:ugid'])
        ugid  = owner.split(':')

        try:
            if islink:
                # -h is short for --no-dereference
                cmd = "/bin/chown -h %s:%s %s" % (ugid[0], ugid[1], path)

                debug(6, "Running command: \"%s\"" % cmd)

                if os.system(cmd):
                    raise PublisherRestoreError("Command failed: \"%s\"" % cmd)
            else:
                os.chown(path, int(ugid[0]), int(ugid[1]))

        except OSError, error:
            raise PublisherRestoreError("Failed to set ownership on \"%s\": %s"
                                        % (path, error))

        try:
            # symlinks are always 777
            if not islink:
                os.chmod(path, perms)
        except OSError, error:
            raise PublisherRestoreError("Failed to set perms on \"%s\": %s"
                                        % (path, error))

        return


    def mkfsball(self, path, branch):
        self.fsball_tempdir = tempfile.mktemp()
        branch_stanza       = None
        target_format_dict  = { 'stanza': None, 'release': self.release,
                                'branch': None, 'ball_type': None }
        cmd_format_dict     = { 'source': None, 'target': None }

        try:
            os.mkdir(self.fsball_tempdir, 0700)
        except OSError, err:
            raise PublisherFSBallError("Couldn't make temp directory: %s"
                                       % err)

        # Get our branch
        target_format_dict['stanza'] = branch_stanza = self.get_stanza(branch)

        # Get our output filename's format
        branch_type = self.config.get(branch_stanza, 'type')
        if branch_type == 'trunk':
            format = self.config.get(branch_stanza, 'trunk_format', raw=1)
        elif branch_type == 'branch':
            format = self.config.get(branch_stanza, 'branch_format', raw=1)
            target_format_dict['branch'] = os.path.basename(branch)
        else:
            os.rmdir(self.fsball_tempdir)
            raise PublisherFSBallError("Unknown tree type \"%s\" for branch "
                                       "\"%s\"" % (branch_type, branch_stanza))

        # What kind of fsball are we creating?
        target_format_dict['ball_type'] = self.config.get(branch_stanza,
                                                          'ball_type')
        ball_type = target_format_dict['ball_type']

        debug(6, "Format dict == %s" % pprint.pformat(target_format_dict))

        outfile = format % target_format_dict


        # Format the actual command to exec based on the type of ball
        cmd_format_dict['source'] = os.path.join(path, branch)
        cmd_format_dict['target'] = os.path.join(self.fsball_tempdir, outfile)

        command = self.config.get(branch_stanza, "%sfs_cmd" % ball_type, raw=1)

        command = command % cmd_format_dict

        debug(6, "Command is: \"%s\"" % command)

        try:
            if os.system(command):
                raise PublisherFSBallError("FS ball creation failed! branch "
                                           "\"%s\"" % branch)
        except OSError, error:
            raise PublisherFSBallError("Couldn't create an FS ball of"
                                       " branch \"%s\": %s" % (branch, error))

        if ball_type == 'iso':
            cmd = None
            try:
                cmd = self.config.get(branch_stanza, 'isofs_compress_cmd',
                                      raw=1)
            except:
                pass

            if cmd is not None and cmd != '':
                cmd = cmd % cmd_format_dict
                
                debug(6, "Command is: \"%s\"" % cmd)
                
                try:
                    if os.system(cmd):
                        raise PublisherFSBallError("FS ball compression "
                                                   "failed for branch "
                                                   "\"%s\"" % branch)
                except OSError, err:
                    raise PublisherFSBallError("FS ball compression failed "
                                               "for branch \"%s\": %s" \
                                               % (branch, err))

                cmd_format_dict['target'] = "%s.gz" % cmd_format_dict['target']

        self.fsballs[branch] = cmd_format_dict['target']


    def cleanup(self):
        # We don't bother with an SVN client cleanup call because we've
        # already deleted all the .svn dirs so all it would do is raise an
        # exception
        for tempdir in (self.tempdir, self.fsball_tempdir):
            try:
                cmd = "/bin/rm -rf %s" % tempdir

                debug(6, "Command is: \"%s\"" % cmd)

                if os.system(cmd):
                    raise PublisherCheckoutError("Command failed: \"%s\"" \
                                                 % cmd)
        
            except OSError, err:
                raise PublisherCheckoutError("Failed to remove temporary "
                                             "directory: %s" % err)


    def publish(self, branch):
        fsball   = self.fsballs[branch]
        stanza   = self.get_stanza(branch)
        target   = self.config.get(stanza, 'publish_to')
        publish  = self.config.get(stanza, 'publish_cmd')

        try:
            cmd = "%s %s %s" % (publish, fsball, target)

            debug(6, "Command is: \"%s\"" % cmd)

            if os.system(cmd):
                raise PublisherPublishingError("Command failed: \"%s\"" % cmd)
        
        except OSError, err:
            raise PublisherPublishingError("Failed to publish branch \"%s\"" \
                                           % err)



#
# Determines which branches have been changed
# Cribbed from subversion-1.1.1/tools/examples/svnlook.py
#
class ChangedBranchHarvester(delta.Editor):
    def __init__(self, results_target):
        self.target = results_target

    def open_root(self, base_revision, dir_pool):
        return [ 1, '' ]

    def delete_entry(self, path, revision, parent_baton, pool):
        self._path_changed(parent_baton)

    def add_directory(self, path, parent_baton,
                      copyfrom_path, copyfrom_revision, dir_pool):
        self._path_changed(parent_baton)
        return [ 1, path ]

    def open_directory(self, path, parent_baton, base_revision, dir_pool):
        return [ 1, path ]

    def change_dir_prop(self, dir_baton, name, value, pool):
        self._path_changed(dir_baton)

    def add_file(self, path, parent_baton,
                 copyfrom_path, copyfrom_revision, file_pool):
        self._path_changed(parent_baton)

    def open_file(self, path, parent_baton, base_revision, file_pool):
        # This covers propery changes as well as text changes
        self._path_changed(parent_baton)

    def _path_changed(self, baton):
        if baton[0]:
            if not self.target.has_key(baton[0]):
                self.target[baton[1]] = 0

            self.target[baton[1]] += 1


def sig_handler(signum, frame):
    signal.signal(signum, signal.SIG_IGN)

    cleanup()
    sys.exit(0)


def cleanup():
    try:
        os.unlink(FIFOPATH)
    except:
        pass

    try:
        syslog.closelog()
    except:
        pass


def main():
    global DEBUG, NO_CLEANUP, NO_PUBLISH, FIFOPATH

    opts, remainder = getopt.getopt(sys.argv[1:], 'c:D:p:',
                                    ['no-publish', 'no-cleanup'])

#    if len(remainder) != 2:
#        print "Need repo and then release number specified on command line."
#        sys.exit(1)
#
#    repo,rev = remainder

    if len(opts) < 1:
        print "No config specified."
        sys.exit(1)

    FIFOPATH = '/var/run/cramfs-publisher.fifo'
    setfifo = 0
    for opt, val in opts:
        if opt == '-c':
            try:
                if not os.path.exists(val):
                    print "Non-existent config file: %s" % val
                    sys.exit(1)

                config = ConfigParser.ConfigParser()
                config.read(val)
            except ConfigParser.Error, err:
                print "Failed to parse config: %s" % err
                sys.exit(1)
        elif opt == '-D':
            try:
                DEBUG = int(val)
            except ValueError:
                print "-d requires an integer argument."
                sys.exit(1)
        elif opt == '-p':
            FIFOPATH = val
            setfifo += 1
        elif opt == '--no-cleanup':
            NO_CLEANUP += 1
        elif opt == '--no-publish':
            NO_PUBLISH += 1
        else:
            print "\"%s\" \"%s\"" % (opt, val)
            print "Blah to the blah blah."
            sys.exit(1)

    #
    # Set up our FIFO
    #
    if setfifo == 0:
        try:
            FIFOPATH = config.get('DEFAULT', 'fifopath')
        except ConfigParser.Error, err:
            pass

    try:
        os.mkfifo(FIFOPATH, 0666)
        # Permissions aren't being set appropriately.  Doesn't seem to be 
        # umask related.  Weirdness, really.
        os.chmod(FIFOPATH, 0666)
    except OSError, err:
        pass

    #
    # Now daemonize
    #
    if (not DEBUG):
        try:
            sys.stderr.close
            sys.stdout.close()
            sys.stdin.close()

            pid = os.fork()

            if (pid > 0):
                debug(6, "Initial parent exiting.")
                sys.exit(0)

            pid = os.fork()

            if (pid > 0):
                debug(6, "Second parent exiting.")
                sys.exit(0)
        except OSError, err:
            print "failed second fork: %s" % err
            cleanup()
            sys.exit(1)

        os.setsid()

    # Logging
    syslog.openlog('spine-cramfs-publisher',
                   syslog.LOG_PID|syslog.LOG_CONS|syslog.LOG_NDELAY,
                   syslog.LOG_DAEMON)

    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    try:
        os.chdir('/tmp')
    except OSError, err:
        pass

    try:
        core.run_app(SpineCRAMFSPublisher, config, FIFOPATH)
    except PublisherError, err:
        print err.msg
        cleanup()
        sys.exit(1)

    cleanup()
    sys.exit(0)

if __name__ == '__main__':
    main()
