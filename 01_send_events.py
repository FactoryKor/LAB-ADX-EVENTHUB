#!/usr/bin/env python3
import os
import json
import time
import random
import argparse
from datetime import datetime, timezone, timedelta

from azure.eventhub import EventHubProducerClient, EventData


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def make_payload(mode: str, i: int, backfill_hours: float = 0.0):
    if mode == "skew":
        # partition skew 재현: 같은 partition key로 몰아넣기
        device_id = "router-hot-001"
        partition_key = "router-hot-001"
        scenario = "partition-skew"
    else:
        device_num = random.randint(1, 100)
        device_id = f"router-{device_num:03d}"
        partition_key = device_id
        scenario = mode

    metric_name = random.choice(["cpu", "memory", "latency", "packet_loss", "queue_depth"])

    # ADX query test를 위해 다양한 값 생성
    metric_value = round(random.uniform(1, 100), 2)

    if metric_value > 90:
        severity = "critical"
    elif metric_value > 70:
        severity = "warning"
    else:
        severity = "info"

    if backfill_hours and backfill_hours > 0:
        # spread timestamps uniformly across the past window (for time-range query / volume tests)
        ts = (datetime.now(timezone.utc)
              - timedelta(seconds=random.uniform(0, backfill_hours * 3600))).isoformat()
    else:
        ts = utc_now()

    payload = {
        "timestamp": ts,
        "deviceId": device_id,
        "partitionKey": partition_key,
        "metricName": metric_name,
        "metricValue": metric_value,
        "severity": severity,
        "scenario": scenario,
        "region": "koreacentral",
        "source": "eh-adx-diag-lab",
        "seq": i,
    }
    return payload, partition_key


def main():
    parser = argparse.ArgumentParser(description="Send test telemetry events to Azure Event Hubs.")
    parser.add_argument("--mode", choices=["normal", "skew", "burst", "badjson", "mismatch"], default="normal")
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--sleep-ms", type=int, default=100)
    parser.add_argument("--backfill-hours", type=float, default=0.0,
                        help="Spread event timestamps across the past N hours (for time-range/volume queries).")
    parser.add_argument("--auth", choices=["connstr", "aad"], default="connstr",
                        help="connstr = SAS connection string (EH_CONN_STR); aad = Entra ID (DefaultAzureCredential).")
    parser.add_argument("--namespace-fqdn", default=None,
                        help="Event Hubs namespace FQDN for --auth aad (defaults to EH_NS_FQDN env).")
    args = parser.parse_args()

    eh_name = os.getenv("EH_NAME", "telemetry-events")

    if args.auth == "aad":
        from azure.identity import DefaultAzureCredential
        fqdn = args.namespace_fqdn or os.getenv("EH_NS_FQDN")
        if not fqdn:
            raise RuntimeError("EH_NS_FQDN is not set (need <namespace>.servicebus.windows.net for --auth aad).")
        producer = EventHubProducerClient(
            fully_qualified_namespace=fqdn,
            eventhub_name=eh_name,
            credential=DefaultAzureCredential(),
        )
        print(f"Auth: Entra ID (DefaultAzureCredential) -> {fqdn}")
    else:
        conn_str = os.getenv("EH_CONN_STR")
        if not conn_str:
            raise RuntimeError("EH_CONN_STR is not set. Run: source ./lab.env")
        producer = EventHubProducerClient.from_connection_string(
            conn_str=conn_str,
            eventhub_name=eh_name
        )

    print(f"Sending events: mode={args.mode}, count={args.count}, batch_size={args.batch_size}")

    sent = 0
    with producer:
        while sent < args.count:
            batch = producer.create_batch()
            current_batch = min(args.batch_size, args.count - sent)

            for _ in range(current_batch):
                sent += 1

                if args.mode == "badjson":
                    # malformed JSON / ingestion failure 테스트용
                    event = EventData("{ this-is-not-valid-json ")
                    event.partition_key = "bad-json"
                    batch.add(event)
                    continue

                payload, partition_key = make_payload(args.mode, sent, args.backfill_hours)

                if args.mode == "mismatch":
                    # mapping/type mismatch 유도: MetricValue를 문자열로 전송
                    payload["metricValue"] = "not-a-number"
                    payload["scenario"] = "mapping-mismatch"

                event = EventData(json.dumps(payload))
                event.content_type = "application/json"
                event.partition_key = partition_key
                batch.add(event)

            producer.send_batch(batch)

            if sent % 1000 == 0 or sent == args.count:
                print(f"sent={sent}/{args.count}")

            if args.mode == "burst":
                # burst는 sleep 없이 밀어넣음
                continue

            time.sleep(args.sleep_ms / 1000.0)

    print("Done.")


if __name__ == "__main__":
    main()