"""Run a scenario: the simulated customer chats with the Netomi agent; print the transcript."""

import uuid

import yaml

from first_available.customer import next_customer_message
from first_available.db import query
from first_available.netomi import get_token, send_message


def load_scenario(path):
    """Read one scenario file (assets/scenarios/*.yaml)."""
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def run_scenario(scenario, after_agent_reply=None):
    """Chat until the customer is done or max_turns is reached.

    Prints the transcript as it goes. after_agent_reply(text), if given, runs after every
    agent reply (Conversation 2 uses it to play "another customer").
    Returns the transcript: a list of (speaker, text) pairs.
    """
    token, conversation_id = get_token(), f"demo-{uuid.uuid4()}"
    transcript, message = [], scenario["opening_message"]
    print(f"=== {scenario['name']} ===\n")
    print("Transcript: the simulated customer (Claude) chatting with the Netomi agent "
          f"(conversationId {conversation_id}, to look up in Netomi).\n")
    for _ in range(scenario["max_turns"]):
        print(f"Customer: {message}\n")
        transcript.append(("Customer", message))
        reply = send_message(token, conversation_id, message)
        print(f"Agent: {reply['text']}\n")
        if reply["sources"]:
            print(f"   Sources: {'; '.join(reply['sources'])}\n")
        transcript.append(("Agent", reply["text"]))
        if after_agent_reply:
            after_agent_reply(reply["text"])
        message = next_customer_message(scenario, transcript)
        if message == "[END]":
            break
    return transcript


def take_earliest_slot(conn, technician="Tessa Nguyen", zip_code="80903", brand="Kestrel"):
    """Conversation 2's "another customer": a hook that books the technician's earliest
    open slot the first time the agent offers times, so the agent must recover."""
    taken = []

    def hook(agent_text):
        if taken or not any(mark in agent_text for mark in ("AM", "PM")):
            return
        result = query(conn, """
            SELECT book_slot(%s,
                             (SELECT to_char(s.start_time AT TIME ZONE 'America/Denver',
                                             'Dy Mon FMDD, FMHH12:MI AM')
                              FROM slots s JOIN technicians t ON t.id = s.technician_id
                              WHERE t.name = %s AND s.status = 'open'
                              ORDER BY s.start_time LIMIT 1),
                             %s, %s, 'Another Customer', 'Dishwasher repair') AS result""",
                       (technician, technician, zip_code, brand))
        taken.append(True)
        print(f"   [another customer just booked {result.loc[0, 'result'].get('time')}]\n")

    return hook


def bookings(conn):
    """Every booking, with its technician and time: the conversations' proof in the database."""
    return query(conn, """
        SELECT b.customer_name, b.issue, t.name AS technician,
               to_char(s.start_time AT TIME ZONE 'America/Denver', 'Dy Mon FMDD, FMHH12:MI AM') AS time
        FROM bookings b
        JOIN slots s ON s.id = b.slot_id
        JOIN technicians t ON t.id = s.technician_id
        ORDER BY b.id""")
