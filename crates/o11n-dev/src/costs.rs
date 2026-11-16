use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::Path;

use regex::{Captures, Regex};

use crate::{settings, stamps};

pub const LOG: &str = "dev/costs.tsv";
// Policy: what is timed between commits waits here, out of git, so that a check run between turns leaves the worktree
// clean; write folds it into LOG.
pub const SPOOL: &str = "dev/state/costs-spool.tsv";
const RECENT: usize = 5;
// Policy: a figure is rewritten only once this far off, lest every turn stamp a new one.
const MARGIN: f64 = 1.5;

// Duplication: dev/check.sh:spool writes these columns, in this order.
#[derive(Debug, Clone, PartialEq)]
pub struct Cost {
    pub when: String,
    pub machine: String,
    pub seconds: f64,
    pub commit: String,
    pub command: String,
}

impl Cost {
    pub fn read(line: &str) -> Result<Cost, String> {
        let fields: Vec<&str> = line.splitn(5, '\t').collect();
        let [when, machine, seconds, commit, command] = fields[..] else {
            return Err(format!("costs: a line without its 5 columns: {line}"));
        };
        Ok(Cost {
            when: when.to_owned(),
            machine: machine.to_owned(),
            seconds: seconds
                .parse()
                .map_err(|_| format!("costs: seconds isn't a number: {line}"))?,
            commit: commit.to_owned(),
            command: command.to_owned(),
        })
    }
}

fn read(paths: &[&Path]) -> Result<Vec<Cost>, String> {
    let mut costs = Vec::new();
    for path in paths {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) if e.kind() == ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("costs: {}: {e}", path.display())),
        };
        for line in text.lines().filter(|line| !line.is_empty()) {
            costs.push(Cost::read(line)?);
        }
    }
    Ok(costs)
}

/// Each command's median over its RECENT latest costs on the machine.
// Accommodating for git, whose union merge of the log leaves its lines out of order: the latest are told by when.
pub fn medians(costs: &[Cost], machine: &str) -> BTreeMap<String, f64> {
    let mut held: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut costs: Vec<&Cost> = costs.iter().filter(|cost| cost.machine == machine).collect();
    costs.sort_by(|a, b| a.when.cmp(&b.when));
    for cost in costs {
        held.entry(cost.command.clone()).or_default().push(cost.seconds);
    }
    held.into_iter()
        .map(|(command, took)| {
            let mut recent = took[took.len().saturating_sub(RECENT)..].to_vec();
            recent.sort_by(f64::total_cmp);
            let half = recent.len() / 2;
            let median = if recent.len() % 2 == 0 {
                f64::midpoint(recent[half - 1], recent[half])
            } else {
                recent[half]
            };
            (command, median)
        })
        .collect()
}

/// The seconds to two significant digits, as a figure quotes them.
fn shown(seconds: f64) -> String {
    format!("{seconds:.1e}")
        .parse::<f64>()
        .map_or_else(|_| seconds.to_string(), |s| s.to_string())
}

fn figure(seconds: f64, m: &Captures) -> String {
    let stated: f64 = m[1].parse().unwrap_or(0.0);
    let off = if stated > 0.0 && seconds > 0.0 {
        (seconds / stated).max(stated / seconds)
    } else {
        0.0
    };
    if off > MARGIN {
        format!("~{}s", shown(seconds))
    } else {
        m[0].to_owned()
    }
}

/// The text, its figures that are off by more than MARGIN made the median.
///
/// A figure is a ~<n>s in a list item whose first code span is the command, and only what a stamp pending holds as
/// written now is read.
pub fn quoted(text: &str, took: &BTreeMap<String, f64>) -> String {
    let figure_at = Regex::new(r"~(\d+(?:\.\d+)?)s\b").expect("a regex");
    let span = Regex::new(r"`([^`]+)`").expect("a regex");
    let item = Regex::new(r"^\s*- ").expect("a regex");
    let mut lines: Vec<String> = text.split_inclusive('\n').map(str::to_owned).collect();
    let shown = stamps::applied_lines(text);
    let mut items: Vec<Vec<usize>> = Vec::new();
    for (at, &n) in shown.iter().enumerate() {
        if item.is_match(&lines[n]) {
            items.push(vec![n]);
        } else if lines[n].starts_with(' ')
            && at > 0
            && items.last().and_then(|item| item.last()) == Some(&shown[at - 1])
        {
            items.last_mut().expect("an item").push(n);
        }
    }
    for item in items {
        let joined: String = item.iter().map(|&n| lines[n].as_str()).collect();
        let Some(seconds) = span.captures(&joined).and_then(|m| took.get(&m[1])) else {
            continue;
        };
        for n in item {
            lines[n] = figure_at
                .replace_all(&lines[n], |m: &Captures| figure(*seconds, m))
                .into_owned();
        }
    }
    lines.concat()
}

/// Folds the spool into the log, if there is one, and rewrites the figures the docs quote off it, of the machine class
/// dev/settings.toml names; says what it wrote.
pub fn write(spool: &Path, log: &Path, quoted_in: &[String], machine: Option<&str>) -> Result<Vec<String>, String> {
    let mut written = Vec::new();
    if !log.exists() {
        return Ok(written);
    }
    if spool.exists() {
        let folded = fs::read_to_string(spool).map_err(|e| format!("costs: {}: {e}", spool.display()))?;
        OpenOptions::new()
            .append(true)
            .open(log)
            .and_then(|mut f| f.write_all(folded.as_bytes()))
            .map_err(|e| format!("costs: {}: {e}", log.display()))?;
        fs::remove_file(spool).map_err(|e| format!("costs: {}: {e}", spool.display()))?;
        written.push(format!("{}: {} folded", log.display(), folded.lines().count()));
    }
    let Some(machine) = machine else {
        return Ok(written);
    };
    let took = medians(&read(&[log])?, machine);
    for path in quoted_in {
        let current = fs::read_to_string(path).map_err(|e| format!("costs: {path}: {e}"))?;
        let now = quoted(&current, &took);
        if now != current {
            fs::write(path, now).map_err(|e| format!("costs: {path}: {e}"))?;
            written.push(format!("{path}: figures rewritten"));
        }
    }
    Ok(written)
}

/// Each command's median per machine, as write would quote it, a line each.
pub fn show(spool: &Path, log: &Path) -> Result<Vec<String>, String> {
    let costs = read(&[log, spool])?;
    let machines: BTreeSet<&str> = costs.iter().map(|cost| cost.machine.as_str()).collect();
    Ok(machines
        .into_iter()
        .flat_map(|machine| {
            medians(&costs, machine)
                .into_iter()
                .map(move |(command, seconds)| format!("{machine}\t{}s\t{command}", shown(seconds)))
        })
        .collect())
}

pub fn written() -> Result<Vec<String>, String> {
    let settings = settings::read()?;
    write(
        Path::new(SPOOL),
        Path::new(LOG),
        &settings.quoted_in,
        settings.quoted.as_deref(),
    )
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;

    use super::{Cost, medians, quoted, write};
    use crate::stamps::{CLOSING, DIVIDER, OPENING};

    fn cost(command: &str, seconds: f64) -> Cost {
        Cost {
            when: "2026-11-12T00:00:00Z".to_owned(),
            machine: "container".to_owned(),
            seconds,
            commit: "abc".to_owned(),
            command: command.to_owned(),
        }
    }

    fn written(cost: &Cost) -> String {
        format!(
            "{}\t{}\t{:.1}\t{}\t{}\n",
            cost.when, cost.machine, cost.seconds, cost.commit, cost.command
        )
    }

    fn took(pairs: &[(&str, f64)]) -> BTreeMap<String, f64> {
        pairs
            .iter()
            .map(|(command, seconds)| ((*command).to_owned(), *seconds))
            .collect()
    }

    #[test]
    fn a_cost_reads_as_it_is_written() {
        let line = written(&cost("dev/check.sh lint", 61.25));
        assert_eq!(Cost::read(line.trim_end()).unwrap(), cost("dev/check.sh lint", 61.2));
        assert!(Cost::read("one\ttwo").is_err());
    }

    #[test]
    fn medians_weigh_the_latest_costs_on_the_machine_by_when() {
        let mut costs: Vec<Cost> = [1.0, 2.0, 3.0, 4.0, 5.0].iter().map(|s| cost("x", *s)).collect();
        costs.push(Cost {
            when: "2026-11-11T00:00:00Z".to_owned(),
            ..cost("x", 900.0)
        });
        costs.push(Cost {
            machine: "devshell".to_owned(),
            ..cost("x", 99.0)
        });
        assert_eq!(medians(&costs, "container"), took(&[("x", 3.0)]));
        assert_eq!(
            medians(&[cost("y", 1.0), cost("y", 2.0)], "container"),
            took(&[("y", 1.5)])
        );
    }

    #[test]
    fn a_figure_is_rewritten_only_once_far_enough_off() {
        let text = "- `dev/check.sh` checks everything ~220s.\n\
                    - `dev/check.sh eval` builds the eval stage, with\n  \
                    its evaluation, ~110s.\n\
                    \n\
                    - `dev/check.sh lint` ~2s, besides `dev/check.sh` ~220s\n";
        let both = took(&[("dev/check.sh", 150.0), ("dev/check.sh eval", 40.0)]);
        assert_eq!(quoted(text, &both), text.replace("~110s", "~40s"));
        assert_eq!(
            quoted(text, &took(&[("dev/check.sh", 120.0)])),
            text.replace("~220s.", "~120s.")
        );
        assert_eq!(quoted("- `x` ~1s\n", &took(&[("x", 0.123)])), "- `x` ~0.12s\n");
    }

    #[test]
    fn a_figure_a_stamp_pending_holds_is_rewritten_as_written_now() {
        let text = format!("{OPENING}\n- `x` ~220s\n{DIVIDER}\n- `x` takes ~220s\n{CLOSING}\n");
        assert_eq!(
            quoted(&text, &took(&[("x", 61.25)])),
            text.replace("takes ~220s", "takes ~61s")
        );
    }

    #[test]
    fn write_folds_the_spool_and_rewrites_the_figures() {
        let dir = std::env::temp_dir().join(format!("o11n-dev-costs-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let (spool, log, doc) = (dir.join("spool"), dir.join("log"), dir.join("doc.md"));
        fs::write(&spool, written(&cost("x", 61.25))).unwrap();
        let docs = [doc.display().to_string()];
        assert_eq!(
            write(&spool, &log, &docs, Some("container")).unwrap(),
            Vec::<String>::new()
        );
        assert!(spool.exists());
        fs::write(&log, "").unwrap();
        fs::write(&doc, "- `x` ~220s\n").unwrap();
        assert_eq!(
            write(&spool, &log, &docs, Some("container")).unwrap(),
            [
                format!("{}: 1 folded", log.display()),
                format!("{}: figures rewritten", doc.display())
            ]
        );
        assert!(!spool.exists());
        assert_eq!(fs::read_to_string(&doc).unwrap(), "- `x` ~61s\n");
        assert_eq!(
            write(&spool, &log, &docs, Some("container")).unwrap(),
            Vec::<String>::new()
        );
        fs::remove_dir_all(&dir).unwrap();
    }
}
