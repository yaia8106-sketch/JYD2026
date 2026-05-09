# Experiment Records

This directory stores reproducible summaries for performance, timing, COE diff, and hotspot experiments.

Use one subdirectory per formal run:

```text
05_Experiment_Records/YYYYMMDD_short_topic/
├── README.md
├── commands.sh
├── env.txt
└── raw/
```

Tracked files must explain:

- purpose and hypothesis
- branch, commit, dirty state, tool versions, and key environment variables
- exact commands and parameters
- key results
- conclusion and next decision

Put full stdout, Vivado reports, and large logs under `raw/`. The `raw/` directory is kept locally and ignored by git.

Default parallelism on this machine is 18 jobs unless a tool-specific issue requires less.
