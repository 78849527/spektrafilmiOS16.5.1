#!/usr/bin/env python3
"""Reusable version floors for historical acceptance audits.

A regression audit for BuildN should enforce its original minimum release,
not falsely require today's app to still report that historical exact build.
The active Build115 workflow separately pins 1.8.81/115 for IPA identity.
"""
import re


def minimum_build(project_yaml: str, build_number: int) -> bool:
    match = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', project_yaml)
    return bool(match) and int(match.group(1)) >= build_number


def minimum_minor(project_yaml: str, minor: int) -> bool:
    match = re.search(r'MARKETING_VERSION:\s*"1\.8\.(\d+)"', project_yaml)
    return bool(match) and int(match.group(1)) >= minor
