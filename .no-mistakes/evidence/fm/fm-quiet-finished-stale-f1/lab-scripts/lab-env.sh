# Source with LAB set: route plain tmux to the lab's fm-lab server, the way a
# lab primary's scripts inherit $TMUX from its pane.
sock="$LAB/tmux/tmux-$(id -u)/fm-lab"
pid=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p '#{pid}')
export TMUX="$sock,$pid,0" FM_HOME="$LAB"
unset TMUX_PANE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
