#!/usr/bin/env python3
"""校验 workflow：GitHub 表达式不得出现在 run 脚本里（只允许 env 赋值与 runner.temp 路径）。"""
import io, re, sys, yaml

path = ".github/workflows/ai-reply.yml"
doc = yaml.safe_load(io.open(path, encoding="utf-8"))
bad = []
for job in doc["jobs"].values():
    for step in job["steps"]:
        run = step.get("run", "")
        for expr in re.findall(r"\$\{\{[^}]*\}\}", run):
            if "runner.temp" in expr.lower():
                continue
            bad.append((step.get("name", "?"), expr))
print("步骤数:", sum(len(j["steps"]) for j in doc["jobs"].values()))
print("YAML 解析: OK")
if bad:
    for name, expr in bad:
        print(f"  ✗ {name} 的 run 里存在表达式插值 {expr}")
    sys.exit(1)
print("  ✓ run 脚本中无用户可控数据插值")
