WB='\[\033[1;37m\]'
GB='\[\033[1;32m\]'
RB='\[\033[1;31m\]'
CB='\[\033[1;36m\]'
DB='\[\033[1;30m\]'
NC='\[\033[0m\]'

if [[ $EUID -eq 0 ]]; then
	PC1=$RB
	PC2=$DB
	PC3=$CB
	PROMPT_CHAR="#"
else
	PC1=$GB
	PC2=$WB
	PC3=$RB
	PROMPT_CHAR="$"
fi

PS1="${PC1}[${USER_COLOR}\u${PC1}@\h:\w]${PC2} \${SHLVL}.\${BASH_SUBSHELL} ${PC3}${PROMPT_CHAR}${NC} "
