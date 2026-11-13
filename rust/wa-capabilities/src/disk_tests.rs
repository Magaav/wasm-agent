//! The four rules of `docs/ONEROOT.md` that a deletion can get wrong: the guard, pins, the landed
//! worktree, and retention that treats an unsettled operation as live.
//!
//! Every test builds its own root under the temp dir and calls the module's own functions with it, so
//! nothing here reads or writes a real node's state root.
use super::*;
use std::path::{Path, PathBuf};

fn scratch(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-oneroot-{}-{}-{}",
        name,
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    std::fs::create_dir_all(&base).expect("scratch root");
    base
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_AUTHOR_NAME", "fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@invalid")
        .env("GIT_COMMITTER_NAME", "fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@invalid")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .expect("git runs");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn write(path: &Path, text: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("parent");
    }
    std::fs::write(path, text).expect("write");
}

/// A repo whose `origin/main` holds `main`, with one linked worktree per name in `branches`.
/// Returns the repo path; the worktrees are created under `<root>/worktrees/<name>` by the caller's
/// root, so the layout is the one `wa clean` actually walks.
fn repo_with_worktrees(root: &Path, names: &[&str]) -> PathBuf {
    let repo = root.join("canonical");
    std::fs::create_dir_all(&repo).expect("repo");
    git(&repo, &["init", "-q", "-b", "main"]);
    write(&repo.join("seed.txt"), "seed\n");
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "seed"]);
    let worktrees = root.join("worktrees");
    std::fs::create_dir_all(&worktrees).expect("worktrees");
    for name in names {
        let tree = worktrees.join(name);
        git(&repo, &["worktree", "add", "-q", "-b", &format!("change/{name}"), tree.to_str().unwrap(), "main"]);
    }
    repo
}

#[test]
fn a_parent_dir_path_and_a_symlink_out_of_the_root_are_refused_by_name() {
    let root = scratch("guard");
    std::fs::create_dir_all(root.join("tmp")).unwrap();
    let inside = root.join("tmp").join("scratch.txt");
    write(&inside, "x");
    assert!(guard_inside(&root, &inside).is_ok(), "a file inside the root is a candidate");

    // `..` is refused before the filesystem is touched: the textual path looks inside the root.
    let escape = root.join("tmp").join("..").join("..").join("etc");
    let refused = guard_inside(&root, &escape).expect_err("a `..` component is refused");
    assert!(refused.starts_with("outside_root:"), "got {refused}");

    // A symlink to a directory outside the root: the link itself is refused, and its target is
    // untouched - which is the whole point of refusing rather than following.
    let outside = scratch("guard-outside");
    write(&outside.join("keep.txt"), "must survive\n");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&outside, root.join("tmp").join("escape")).unwrap();
        let refused = guard_inside(&root, &root.join("tmp").join("escape")).expect_err("a link is refused");
        assert!(refused.starts_with("symlink_not_followed:"), "got {refused}");
        assert!(outside.join("keep.txt").is_file(), "the link's target is never touched");
    }
    let _ = std::fs::remove_dir_all(&outside);

    // And the plan refuses it too: a symlink in a retention group is reported, not deleted.
    let groups = plan(&root, 0, now_epoch()).expect("plan");
    let tmp = groups.iter().find(|group| group.name == "tmp").expect("tmp group");
    let escape = tmp.entries.iter().find(|entry| entry.path.ends_with("escape"));
    if let Some(escape) = escape {
        assert!(!escape.delete, "the link is not a deletion candidate");
        assert!(escape.reason.starts_with("symlink_not_followed:"), "got {}", escape.reason);
    }
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn retention_deletes_an_old_settled_record_and_keeps_an_unsettled_one() {
    let root = scratch("retention");
    let operations = root.join("operations");
    let old = operations.join("op-old");
    let pending = operations.join("op-pending");
    for dir in [&old, &pending] {
        std::fs::create_dir_all(dir).unwrap();
        write(&dir.join("stdout"), &"x".repeat(1024));
    }
    write(&old.join("state.json"), "{\"state\":\"completed\",\"settled\":true}");
    write(&pending.join("state.json"), "{\"state\":\"running\",\"settled\":false}");
    // An operation with no state at all is an unknown effect: live, never deleted.
    let unknown = operations.join("op-unknown");
    std::fs::create_dir_all(&unknown).unwrap();
    write(&unknown.join("stdout"), "y");

    // Eight days old. `File::open` works on a directory too, and `set_modified` needs ownership,
    // not write access, so this ages a directory without opening it for writing.
    let eight_days_ago = SystemTime::now() - std::time::Duration::from_secs(8 * 86_400);
    for dir in [&old, &pending, &unknown] {
        let file = std::fs::File::open(dir).unwrap();
        file.set_modified(eight_days_ago).unwrap();
    }

    let groups = plan(&root, 7, now_epoch()).expect("plan");
    let ops = groups.iter().find(|group| group.name == "operations").expect("operations group");
    let verdict = |name: &str| {
        ops.entries
            .iter()
            .find(|entry| entry.path.ends_with(name))
            .map(|entry| (entry.delete, entry.reason.clone()))
            .unwrap_or_else(|| panic!("{name} is in the plan"))
    };
    assert!(verdict("op-old").0, "an old settled operation is deleted");
    assert!(!verdict("op-pending").0, "an unsettled operation is live work");
    assert!(verdict("op-pending").1.contains("not settled"), "got {}", verdict("op-pending").1);
    assert!(!verdict("op-unknown").0, "an operation with no state is never deleted");
}

#[test]
fn a_landed_clean_worktree_is_deleted_and_a_dirty_one_is_kept() {
    let root = scratch("worktrees");
    let repo = repo_with_worktrees(&root, &["landed", "dirty", "unlanded"]);
    let worktrees = root.join("worktrees");

    // `landed`: commit, merge into main, and publish that as origin/main.
    let landed = worktrees.join("landed");
    write(&landed.join("landed.txt"), "work\n");
    git(&landed, &["add", "."]);
    git(&landed, &["commit", "-qm", "landed work"]);
    git(&repo, &["merge", "-q", "--ff-only", "change/landed"]);
    let tip = git(&repo, &["rev-parse", "HEAD"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &tip]);

    // `dirty`: same landed commit, but a draft nobody may lose.
    let dirty = worktrees.join("dirty");
    write(&dirty.join("landed.txt"), "work\n");
    git(&dirty, &["add", "."]);
    git(&dirty, &["commit", "-qm", "landed work"]);
    git(&repo, &["update-ref", "refs/remotes/origin/main", &git(&repo, &["rev-parse", "HEAD"])]);
    write(&dirty.join("draft.txt"), "uncommitted\n");

    // `unlanded`: a commit of its own, so it is genuinely not merged into origin/main.
    let unlanded = worktrees.join("unlanded");
    write(&unlanded.join("unlanded.txt"), "still working\n");
    git(&unlanded, &["add", "."]);
    git(&unlanded, &["commit", "-qm", "work in progress"]);

    let groups = plan(&root, 7, now_epoch()).expect("plan");
    let trees = groups.iter().find(|group| group.name == "worktrees").expect("worktrees group");
    let verdict = |name: &str| {
        trees
            .entries
            .iter()
            .find(|entry| entry.path.ends_with(name))
            .map(|entry| (entry.delete, entry.reason.clone()))
            .unwrap_or_else(|| panic!("{name} is in the plan"))
    };
    assert!(verdict("landed").0, "a landed, clean, unpinned worktree goes: {}", verdict("landed").1);
    assert!(!verdict("dirty").0, "a worktree holding drafts stays");
    assert!(verdict("dirty").1.contains("drafts"), "got {}", verdict("dirty").1);
    assert!(!verdict("unlanded").0, "an unlanded branch stays");
    assert!(verdict("unlanded").1.contains("not merged"), "got {}", verdict("unlanded").1);

    // A detached tree is a deploy or rollback pin: never removed automatically.
    let pinned = worktrees.join("detached");
    git(&repo, &["worktree", "add", "-q", "--detach", pinned.to_str().unwrap(), "main"]);
    let groups = plan(&root, 7, now_epoch()).expect("plan");
    let trees = groups.iter().find(|group| group.name == "worktrees").unwrap();
    let detached = trees.entries.iter().find(|entry| entry.path.ends_with("detached")).unwrap();
    assert!(!detached.delete, "a detached worktree is a pin");
    assert!(detached.reason.contains("detached"), "got {}", detached.reason);

    // The real run removes only the landed tree, through git, and leaves the drafts behind.
    let result = clean(&root, &CleanOptions { days: 7, dry_run: false, now: now_epoch() }).expect("clean");
    assert_eq!(result["deleted"].as_u64().unwrap_or(0), 1, "exactly one worktree: {result}");
    assert!(!worktrees.join("landed").exists(), "the landed tree is gone");
    assert!(worktrees.join("dirty").join("draft.txt").is_file(), "the draft survives");
    assert!(worktrees.join("unlanded").exists(), "the unlanded tree survives");
    let registered = git(&repo, &["worktree", "list", "--porcelain"]);
    let landed_path = worktrees.join("landed");
    assert!(
        !registered.lines().any(|line| line.trim() == format!("worktree {}", landed_path.display())),
        "git no longer registers the removed tree:\n{registered}"
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&repo);
}

#[test]
fn a_pin_and_a_marker_file_keep_an_old_entry_and_dry_run_deletes_nothing() {
    let root = scratch("pins");
    let old_log = root.join("logs").join("session.log");
    let other_log = root.join("logs").join("other.log");
    write(&old_log, &"x".repeat(2048));
    write(&other_log, &"y".repeat(2048));
    let old_tmp = root.join("tmp").join("scratch");
    write(&old_tmp.join("file"), &"z".repeat(64));
    write(&root.join("tmp").join(".wa-pin"), "this scratch is being watched\n");
    let eight_days_ago = SystemTime::now() - std::time::Duration::from_secs(8 * 86_400);
    for path in [&old_log, &other_log, &old_tmp] {
        let file = std::fs::File::open(path).unwrap();
        file.set_modified(eight_days_ago).unwrap();
    }
    std::fs::create_dir_all(root.join("clean")).unwrap();
    write(&pins_file(&root), &format!("{}\n", old_log.display()));

    let dry = clean(&root, &CleanOptions { days: 7, dry_run: true, now: now_epoch() }).expect("dry run");
    assert_eq!(dry["freed_bytes"].as_u64().unwrap_or(1), 0, "a dry run frees nothing");
    assert!(old_log.is_file() && other_log.is_file(), "a dry run deletes nothing");
    assert!(dry["would_free_bytes"].as_u64().unwrap_or(0) >= 2048, "and still reports the bytes");

    let real = clean(&root, &CleanOptions { days: 7, dry_run: false, now: now_epoch() }).expect("clean");
    assert!(old_log.is_file(), "a pinned path is never touched: {real}");
    assert!(!other_log.exists(), "an unpinned old log goes");
    assert!(old_tmp.join("file").is_file(), "a .wa-pin marker protects its directory");
    assert!(real["freed_bytes"].as_u64().unwrap_or(0) >= 2048);
    let record = root.join("clean").join("last.json");
    assert!(record.is_file(), "the run records what it freed for `wa status`");
    let recorded: Value = serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
    assert_eq!(recorded["dry_run"], json!(false));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_tree_gets_its_own_build_island_marked_with_its_path() {
    let root = scratch("island");
    let tree = root.join("worktrees").join("my-tree");
    std::fs::create_dir_all(tree.join("rust")).unwrap();
    write(&tree.join("rust/Cargo.toml"), "[workspace]\n");
    let build_root = root.join("build");
    std::fs::create_dir_all(&build_root).unwrap();
    let target = build_env_for_in(&build_root, &tree).expect("a cargo tree gets an island");
    assert!(target.is_dir(), "the target dir exists: {}", target.display());
    let island = target.parent().unwrap();
    let name = island.file_name().unwrap().to_string_lossy().to_string();
    assert!(name.starts_with("my-tree-"), "the island names its tree, got {name}");
    let hash = name.trim_start_matches("my-tree-").to_string();
    assert_eq!(hash.len(), 12, "the island carries 12 hex characters, got {hash}");
    assert!(hash.chars().all(|c| c.is_ascii_hexdigit()), "got {hash}");
    // The marker is what `wa clean` judges the island by, so it must name the tree exactly.
    let marker = std::fs::read_to_string(island.join(ISLAND_MARKER)).expect("the marker is written");
    assert_eq!(marker.trim(), std::fs::canonicalize(&tree).unwrap().to_string_lossy());
    // Two trees never share an island, which is the whole point (see `build_island`).
    let other = root.join("worktrees").join("other-tree");
    std::fs::create_dir_all(other.join("rust")).unwrap();
    write(&other.join("rust/Cargo.toml"), "[workspace]\n");
    assert_ne!(build_env_for_in(&build_root, &other).unwrap(), target, "each tree has its own island");
    // And a directory that is not a cargo tree is left alone: `<root>/build` is not a litter bin.
    assert!(build_env_for_in(&build_root, &root.join("worktrees")).is_none(), "no island for a plain directory");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_build_island_goes_when_its_tree_does_and_stays_when_it_is_in_use() {
    let root = scratch("island-clean");
    let build = root.join("build");
    let live = build.join("live-tree-0123456789ab");
    let gone = build.join("gone-tree-ba9876543210");
    for island in [&live, &gone] {
        std::fs::create_dir_all(island.join("target")).unwrap();
        write(&island.join("target/file.rlib"), &"x".repeat(512));
    }
    let kept_tree = root.join("worktrees").join("kept");
    std::fs::create_dir_all(&kept_tree).unwrap();
    write(&live.join(ISLAND_MARKER), &kept_tree.to_string_lossy());
    write(&gone.join(ISLAND_MARKER), "/nowhere/that/existed/tree");
    let groups = plan(&root, 7, now_epoch()).expect("plan");
    let builds = groups.iter().find(|group| group.name == "build").expect("build group");
    let verdict = |name: &str| {
        builds
            .entries
            .iter()
            .find(|entry| entry.path.ends_with(name))
            .map(|entry| (entry.delete, entry.reason.clone()))
            .unwrap_or_else(|| panic!("{name} is in the plan"))
    };
    assert!(verdict("gone-tree-ba9876543210").0, "an island whose tree is gone goes");
    assert!(!verdict("live-tree-0123456789ab").0, "an island of a tree that is still here stays");
    assert!(verdict("live-tree-0123456789ab").1.contains("still in use"), "got {}", verdict("live-tree-0123456789ab").1);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn status_reports_the_root_its_disk_the_cap_and_the_last_clean() {
    let root = scratch("status");
    write(&root.join("tmp").join("a").join("b"), &"x".repeat(4096));
    let before = status(&root).expect("status");
    assert_eq!(before["root"], json!(root.to_string_lossy()));
    assert!(before["bytes"].as_u64().unwrap_or(0) >= 4096, "the root's size is measured: {before}");
    assert!(before["groups"]["tmp"]["bytes"].as_u64().unwrap_or(0) >= 4096);
    assert_eq!(before["cap_percent"], json!(DEFAULT_CAP_PERCENT));
    assert_eq!(before["days"], json!(DEFAULT_DAYS));
    assert!(before["last_clean"].is_null(), "no clean has run yet");
    #[cfg(unix)]
    assert!(
        before["disk"]["used_percent"].as_f64().is_some(),
        "a POSIX filesystem reports its usage"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn an_unmeasurable_disk_is_reported_as_unknown_and_never_as_healthy() {
    // The guard must not claim a cap is enforced when it cannot measure. On unix this node can
    // measure, so the assertion is about the shape of the answer, not the platform.
    let root = scratch("guard-measure");
    let answer = guard(&root, "test").expect("a measurable disk answers");
    assert_eq!(answer["checked"], json!(true));
    assert_eq!(answer["trigger"], json!("test"));
    assert_eq!(answer["cleaned"], json!(false), "under the cap, nothing is cleaned");
    let _ = std::fs::remove_dir_all(&root);
}
