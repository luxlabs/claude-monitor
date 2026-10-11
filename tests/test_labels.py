import json
import unittest
from pathlib import Path

from claude_monitor import labels

FIXTURES = Path(__file__).parent / "fixtures"


class LabelsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((FIXTURES / "labels.json").read_text())

    def test_models(self):
        for model, expected in self.data["models"]:
            with self.subTest(model=model):
                self.assertEqual(labels.short_model(model), expected)

    def test_modes(self):
        for mode, expected in self.data["modes"]:
            with self.subTest(mode=mode):
                self.assertEqual(labels.short_mode(mode), expected)

    def test_limits(self):
        for limit, expected in self.data["limits"]:
            with self.subTest(limit=limit):
                self.assertEqual(labels.limit_label(limit), expected)

    def test_tokens(self):
        for count, expected in self.data["tokens"]:
            with self.subTest(count=count):
                self.assertEqual(labels.format_tokens(count), expected)


if __name__ == "__main__":
    unittest.main()
