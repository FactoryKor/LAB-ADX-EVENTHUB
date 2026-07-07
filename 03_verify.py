#!/usr/bin/env python3
"""
03_verify.py — Assertion harness for the Event Hub + ADX diagnostic lab.

Runs a set of KQL checks against ADX and prints PASS / WARN / FAIL for each,
so you can confirm the signals that eh_diagnose / adx_diagnose are expected to
detect actually landed. Uses Azure CLI auth (run `az login` first).

Env (from lab.env):
    ADX_QUERY_URI   e.g. https://adxdiagXXXX.koreacentral.kusto.windows.net
    ADX_DB          e.g. diagdb
    ADX_TABLE       e.g. TelemetryRaw   (optional, default TelemetryRaw)
"""
import os
import sys

from azure.kusto.data import KustoClient, KustoConnectionStringBuilder


def get_client_and_db():
    uri = os.getenv("ADX_QUERY_URI")
    if not uri:
        cluster = os.getenv("ADX_CLUSTER")
        location = os.getenv("LOCATION")
        if not (cluster and location):
            raise RuntimeError("Set ADX_QUERY_URI (or ADX_CLUSTER + LOCATION). Run: source ./lab.env")
        uri = f"https://{cluster}.{location}.kusto.windows.net"
    db = os.getenv("ADX_DB", "diagdb")
    kcsb = KustoConnectionStringBuilder.with_az_cli_authentication(uri)
    return KustoClient(kcsb), db, uri


def rows(resp):
    return list(resp.primary_results[0])


def report(name, status, detail=""):
    icon = {"PASS": "[PASS]", "WARN": "[WARN]", "FAIL": "[FAIL]", "INFO": "[INFO]"}.get(status, status)
    print(f"{icon} {name}" + (f" — {detail}" if detail else ""))


def main():
    client, db, uri = get_client_and_db()
    table = os.getenv("ADX_TABLE", "TelemetryRaw")
    print(f"ADX: {uri}  db={db}  table={table}\n" + "=" * 60)

    # 1) Total rows ingested
    try:
        r = rows(client.execute(db, f"{table} | count"))
        total = r[0]["Count"] if r else 0
        report("Ingestion: total rows", "PASS" if total > 0 else "FAIL", f"count={total}")
    except Exception as e:
        report("Ingestion: total rows", "FAIL", str(e))
        total = 0

    # 2) Scenario breakdown
    try:
        r = rows(client.execute(db, f"{table} | summarize Count=count() by Scenario | order by Count desc"))
        detail = ", ".join(f"{row['Scenario']}={row['Count']}" for row in r) or "none"
        report("Scenario breakdown", "INFO", detail)
    except Exception as e:
        report("Scenario breakdown", "WARN", str(e))

    # 3) Partition skew — top partition key share
    try:
        q = (f"{table} | summarize c=count() by PartitionKey "
             f"| top 1 by c desc | extend total=toscalar({table} | count) "
             f"| extend share=round(100.0*c/total,1)")
        r = rows(client.execute(db, q))
        if r:
            row = r[0]
            share = row["share"]
            status = "WARN" if share and share >= 30 else "INFO"
            report("Partition skew: hottest key", status, f"{row['PartitionKey']} = {share}% of rows")
    except Exception as e:
        report("Partition skew", "WARN", str(e))

    # 4) Ingestion failures (bad JSON / mapping mismatch tests)
    try:
        r = rows(client.execute_mgmt(db, ".show ingestion failures | count"))
        fails = r[0]["Count"] if r else 0
        report("Ingestion failures (.show ingestion failures)", "INFO",
               f"count={fails} (expect > 0 after badjson/mismatch runs)")
    except Exception as e:
        report("Ingestion failures", "WARN", str(e))

    # 5) Severity distribution (query-content sanity)
    try:
        r = rows(client.execute(db, f"{table} | summarize c=count() by Severity | order by c desc"))
        detail = ", ".join(f"{row['Severity']}={row['c']}" for row in r) or "none"
        report("Severity distribution", "INFO", detail)
    except Exception as e:
        report("Severity distribution", "WARN", str(e))

    # 6) Ingestion latency (enqueue -> ingestion time)
    try:
        q = (f"{table} | where isnotempty(EventHubEnqueuedTime) "
             f"| extend lat = ingestion_time() - EventHubEnqueuedTime "
             f"| summarize p50=percentile(lat,50), p95=percentile(lat,95), maxLat=max(lat)")
        r = rows(client.execute(db, q))
        if r:
            row = r[0]
            report("Ingestion latency (enqueue->ingest)", "INFO",
                   f"p50={row['p50']}, p95={row['p95']}, max={row['maxLat']}")
    except Exception as e:
        report("Ingestion latency", "WARN", str(e))

    print("=" * 60)
    print("Note: WARN/INFO are diagnostic hints, not hard failures. Run the")
    print("relevant scenario (skew/badjson/mismatch/burst) before asserting.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
