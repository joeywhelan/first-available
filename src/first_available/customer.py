"""The simulated customer: Claude plays a persona from a scenario file."""

import functools
import os

import anthropic
from dotenv import load_dotenv

load_dotenv()

RULES = """
You are role-playing a customer chatting with an appliance-repair support agent.
Stay in character as the person described below.
- Reply with only the customer's next chat message: no quotes, labels, or commentary.
- Keep it short, like a real chat message.
- As soon as your goal is met, or the conversation is clearly over, reply with exactly [END].
  Don't thank the agent or ask follow-up questions first.
- If the agent says it's transferring you to a human agent, the conversation is over: reply [END].
"""


@functools.cache
def client():
    """One shared Anthropic client (reads ANTHROPIC_API_KEY from .env)."""
    return anthropic.Anthropic()


def next_customer_message(scenario, transcript):
    """Ask Claude for the customer's next message, given the conversation so far.

    transcript is a list of (speaker, text) pairs, speaker being "Customer" or "Agent".
    Returns the message text, or "[END]" when the customer is done.
    """
    conversation = "\n".join(f"{speaker}: {text}" for speaker, text in transcript)
    response = client().beta.messages.create(
        model=os.environ["CUSTOMER_MODEL"],
        max_tokens=4000,
        system=f"{RULES}\nYour persona: {scenario['persona']}\nYour goal: {scenario['goal']}",
        messages=[{"role": "user", "content":
                   f"The chat so far:\n\n{conversation}\n\nWrite the customer's next message."}],
        output_config={"effort": "low"},  # short chat replies don't need deep thinking
        # If a safety classifier declines (e.g. the prompt-injection persona), the API
        # retries the same request on a fallback model instead of returning a refusal.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
    )
    if response.stop_reason == "refusal":
        return "[END]"
    return "".join(b.text for b in response.content if b.type == "text").strip()
