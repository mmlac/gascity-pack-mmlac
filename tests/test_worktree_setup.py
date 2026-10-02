import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "assets/scripts/worktree-setup.sh"


class WorktreeSetupTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="worktree-setup-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "repo"
        self.target = self.root / "worktrees" / "worker"
        self.env = dict(
            os.environ,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Worktree test",
            GIT_AUTHOR_EMAIL="worktree@test.invalid",
            GIT_COMMITTER_NAME="Worktree test",
            GIT_COMMITTER_EMAIL="worktree@test.invalid",
        )
        self.run_command("git", "init", "-q", "--initial-branch=main", self.repo)
        self.git(self.repo, "commit", "-q", "--allow-empty", "-m", "Initial")

    def run_command(self, *args):
        result = subprocess.run(
            [str(arg) for arg in args],
            env=self.env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def git(self, repo, *args):
        return self.run_command("git", "-C", repo, *args)

    def setup_worktree(self, *flags):
        self.run_command("sh", SCRIPT, self.repo, self.target, "worker", *flags)

    def test_fresh_local_worktree(self):
        self.setup_worktree()
        self.assertEqual(
            self.git(self.target, "rev-parse", "HEAD"),
            self.git(self.repo, "rev-parse", "HEAD"),
        )
        self.assertEqual(
            (self.target / ".beads/redirect").read_text().strip(),
            str(self.repo / ".beads"),
        )
        self.assertEqual(self.git(self.target, "status", "--porcelain"), "")

    def test_fresh_sync_starts_from_upstream_not_local_head(self):
        origin = self.root / "origin.git"
        self.run_command("git", "clone", "-q", "--bare", self.repo, origin)
        self.git(self.repo, "remote", "add", "origin", str(origin))
        self.git(self.repo, "fetch", "-q", "origin")
        self.git(self.repo, "remote", "set-head", "origin", "main")
        upstream = self.git(self.repo, "rev-parse", "origin/main")
        self.git(self.repo, "commit", "-q", "--allow-empty", "-m", "Local only")
        self.setup_worktree("--sync")
        self.assertEqual(self.git(self.target, "rev-parse", "HEAD"), upstream)

    def test_legacy_signature(self):
        city = self.root / "city"
        self.run_command("sh", SCRIPT, self.repo, "worker", city)
        target = city / ".gc/worktrees/repo/worker"
        self.assertEqual(
            self.git(target, "rev-parse", "HEAD"),
            self.git(self.repo, "rev-parse", "HEAD"),
        )

    def test_second_call_without_sync_preserves_work(self):
        self.setup_worktree()
        work = self.target / "unfinished.txt"
        work.write_text("Keep this work\n")
        self.setup_worktree()
        self.assertEqual(work.read_text(), "Keep this work\n")


if __name__ == "__main__":
    unittest.main()
