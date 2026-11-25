# Themis
Themis is a command-line tool that provides a clear, visual summary of resource usage across nodes in SLURM partitions. It helps users quickly identify available resources (CPU, GPU, memory) and understand how they're being utilized. It relies on `sinfo`, `squeue` and `scontrol`.


## Download

To download themis just clone the directory:
```bash
git clone https://github.com/Rigo-99/Themis.git
cd Themis
chmod +x themis.sh
```


## Usage

```bash
./themis.sh [-u USER] <partition>
```

**Arguments:**
- `<partition>` - Name of the SLURM partition to monitor

**Options:**
- `-u, --user USER` - Highlight a specific user's resource usage in red (default: `$USER`, i.e. yourself). Use this to inspect another user's allocations.
- `-h, --help` - Display help message

### Output

Themis displays a node-level usage table with visual resource bars for each node showing:

- CPU usage
- GPU usage
- Memory usage

#### Resource Bar Legend

Each resource bar uses color-coded symbols to indicate allocation status:

| Symbol | Color | Meaning |
|--------|-------|---------|
| `#` | Red | Resources used by your jobs |
| `+` | Yellow | Resources used by other users' jobs |
| `-` | Green | Free/available resources |
| `@` | Gray | Unavailable resources |

#### Bar Display Modes

- **`[...]`** - Normal display when resources fit within the allocated space
- **`{...}`** - Scaled display when total resources exceed the dedicated space (bars are proportionally scaled)

### Features

- **Quick Resource Overview**: Instantly see which nodes have available resources
- **Personal Job Tracking**: Easily identify where your jobs are running
- **Partition-Wide Visibility**: Monitor entire partition utilization at a glance
- **Scalable Visualization**: Automatically adjusts display for partitions with varying resource counts

### Shell Alias

If you regularly check the same partition, you can set up a shell alias so you don't have to type the full path and partition name every time. Add the following line to your `~/.bashrc` (or `~/.zshrc`) file, replacing `your_alias`, `/path/to/themis.sh` and `your_partition` with your own values:

```bash
alias your_alias='/path/to/themis.sh your_partition'
```

Then reload your shell configuration (`source ~/.bashrc`) and simply run `your_alias` (optionally with `-u USER`) to check the partition.
