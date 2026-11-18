import os
import shutil
import sqlite3
import tempfile
import unittest

import helpers  # noqa: F401
import guard
import subagents

TABLE = {
    500: (400, "python3 /x/hooks/herdr.py stop"),
    400: (300, "/opt/homebrew/bin/codex --no-daemon -m gpt-6-luna"),
    300: (200, "-zsh"),
    200: (1, "herdr-core"),
    # A shell between the hook and Codex (it didn't exec python).
    510: (505, "python3 /x/hooks/herdr.py stop"),
    505: (400, "/bin/zsh -lc ..."),
    # npm's wrapper: node is the foreground, the native binary its child.
    610: (600, "codex"),
    600: (590, "node /usr/local/bin/codex"),
    590: (300, "-zsh"),
    # The shared daemon runs the hooks; it was started from terminal 1's Codex.
    710: (700, "python3 herdr.py stop"),
    700: (400, "/opt/homebrew/bin/codex app-server --listen unix://"),
}


class Guard(unittest.TestCase):
    def test_codex_is_the_parent(self):
        self.assertEqual(guard.codex_pid(400, 400, TABLE.get), 400)
        self.assertEqual(guard.codex_pid(400, 505, TABLE.get), 400)
        self.assertEqual(guard.codex_pid(600, 610, TABLE.get), 600)

    def test_not_an_ancestor(self):
        self.assertIsNone(guard.codex_pid(999, 400, TABLE.get))
        self.assertIsNone(guard.codex_pid(None, 400, TABLE.get))
        self.assertIsNone(guard.codex_pid(1, 400, TABLE.get))

    def test_app_server_in_between(self):
        self.assertIsNone(guard.codex_pid(400, 700, TABLE.get))

    def test_depth(self):
        self.assertIsNone(guard.codex_pid(200, 505, TABLE.get, depth=3))
        self.assertEqual([p for p, _ in guard.chain(510, TABLE.get)], [510, 505, 400, 300])

    def test_real_ps(self):
        table = guard.ps_table()
        self.assertEqual(guard.codex_pid(os.getppid(), os.getpid(), table.get), os.getppid())

    def test_exec_in_the_foreground(self):
        self.assertTrue(guard.foreground_runs_exec(["codex", "exec", "hi"]))
        self.assertTrue(guard.foreground_runs_exec(["codex", "-m", "x", "exec", "hi"]))
        self.assertFalse(guard.foreground_runs_exec(["codex", "--no-daemon"]))
        self.assertFalse(guard.foreground_runs_exec(None))


class Subagents(unittest.TestCase):
    def test_closed_agents_of_the_tree(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d, True)
        db = os.path.join(d, "state_5.sqlite")
        c = sqlite3.connect(db)
        c.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL)")
        c.executemany("INSERT INTO thread_spawn_edges VALUES (?,?,?)", [
            ("root", "a", "open"), ("root", "b", "closed"), ("a", "a1", "closed"), ("b", "b1", "open"), ("other", "x", "closed"),
        ])
        c.commit()
        c.close()
        self.assertEqual(subagents.state_db(d), db)
        self.assertEqual(subagents.closed_agents(db, "root"), {"b", "a1"})
        self.assertEqual(subagents.closed_agents(db, "nobody"), set())
        self.assertEqual(subagents.closed_agents(os.path.join(d, "missing.sqlite"), "root"), set())
        self.assertEqual(subagents.closed_agents(None, "root"), set())

    def test_working_agents(self):
        agents = subagents.mark({}, "a", "active", "t1")
        self.assertEqual(subagents.working(agents), 1)
        agents = subagents.mark(agents, "a", "done", "t1")
        self.assertEqual(subagents.working(agents), 0)
        # The turn's last model-request hook lands after its SubagentStop hook.
        agents = subagents.mark(agents, "a", "active", "t1")
        self.assertEqual(subagents.working(agents), 0)
        # A follow-up turn, and another agent.
        agents = subagents.mark(agents, "a", "active", "t2")
        agents = subagents.mark(agents, "b", "active", "u1")
        self.assertEqual(subagents.working(agents), 2)
        # A late hook of the old turn doesn't hide the new one.
        agents = subagents.mark(agents, "a", "active", "t1")
        self.assertEqual(subagents.working(agents), 2)
        self.assertEqual(subagents.working(agents, closed={"b"}), 1)
        self.assertEqual(agents["a"], {"active": ["t2", "t1"], "done": ["t1"]})


if __name__ == "__main__":
    unittest.main()
