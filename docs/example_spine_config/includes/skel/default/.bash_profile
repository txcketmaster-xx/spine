#
# managed by rubix
#
# consult your friendly neighborhood admin team for updates or additions
#

PS1="[\u@\H \W]\\$ "

if [ -f ~/.bashrc ]; then
	. ~/.bashrc
fi

if [ -d ~/bin ] ; then
	PATH=~/bin:"${PATH}"
fi

if [ -r $HOME/.bash_extra ] ; then
    . $HOME/.bash_extra
fi
