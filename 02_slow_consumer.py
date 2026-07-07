#!/usr/bin/env python3
import os
import time
import argparse

from azure.eventhub import EventHubConsumerClient


def on_event(partition_context, event):
    print(
        f"received partition={partition_context.partition_id}, "
        f"seq={event.sequence_number}, "
        f"offset={event.offset}"
    )

    # 일부러 느리게 처리
    time.sleep(SLEEP_SECONDS)

    # checkpoint를 너무 자주 하지 않으면 lag 관찰이 쉬움
    if event.sequence_number % CHECKPOINT_EVERY == 0:
        partition_context.update_checkpoint(event)
        print(f"checkpoint updated: partition={partition_context.partition_id}, seq={event.sequence_number}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Slow consumer for Event Hubs lag simulation.")
    parser.add_argument("--sleep-seconds", type=float, default=2.0)
    parser.add_argument("--checkpoint-every", type=int, default=50)
    parser.add_argument("--consumer-group", default=os.getenv("EH_CG_SLOW", "slow-cg"))
    parser.add_argument("--auth", choices=["connstr", "aad"], default="connstr",
                        help="connstr = SAS (EH_CONN_STR); aad = Entra ID (DefaultAzureCredential).")
    parser.add_argument("--namespace-fqdn", default=None,
                        help="Event Hubs namespace FQDN for --auth aad (defaults to EH_NS_FQDN env).")
    parser.add_argument("--no-checkpoint-store", action="store_true",
                        help="Force in-memory checkpoints even if STORAGE_CONN_STR is set.")
    args = parser.parse_args()

    SLEEP_SECONDS = args.sleep_seconds
    CHECKPOINT_EVERY = args.checkpoint_every

    eh_name = os.getenv("EH_NAME", "telemetry-events")

    # Optional durable checkpoint store (Blob) so checkpoints persist and lag can be
    # observed reliably across restarts / multiple consumers.
    checkpoint_store = None
    storage_conn = os.getenv("STORAGE_CONN_STR")
    container = os.getenv("BLOB_CONTAINER", "checkpoints")
    if storage_conn and not args.no_checkpoint_store:
        from azure.eventhub.extensions.checkpointstoreblob import BlobCheckpointStore
        checkpoint_store = BlobCheckpointStore.from_connection_string(storage_conn, container)
        print(f"Checkpoint store: Blob container '{container}'")
    else:
        print("Checkpoint store: in-memory (checkpoints will not persist across restarts)")

    common = dict(consumer_group=args.consumer_group, eventhub_name=eh_name,
                  checkpoint_store=checkpoint_store)

    if args.auth == "aad":
        from azure.identity import DefaultAzureCredential
        fqdn = args.namespace_fqdn or os.getenv("EH_NS_FQDN")
        if not fqdn:
            raise RuntimeError("EH_NS_FQDN is not set (need <namespace>.servicebus.windows.net for --auth aad).")
        client = EventHubConsumerClient(
            fully_qualified_namespace=fqdn,
            credential=DefaultAzureCredential(),
            **common
        )
        print(f"Auth: Entra ID (DefaultAzureCredential) -> {fqdn}")
    else:
        conn_str = os.getenv("EH_CONN_STR")
        if not conn_str:
            raise RuntimeError("EH_CONN_STR is not set. Run: source ./lab.env")
        client = EventHubConsumerClient.from_connection_string(
            conn_str=conn_str,
            **common
        )

    print(f"Starting slow consumer. consumer_group={args.consumer_group}, sleep={SLEEP_SECONDS}s")

    with client:
        client.receive(
            on_event=on_event,
            starting_position="-1"
        )