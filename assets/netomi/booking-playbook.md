# Summit Home Services: booking playbook

A Netomi **Text** playbook (Build → AI Agent Tools → Playbooks → Add → Text). Paste each part into its field.
- In the Procedure, retype every `@tool` with the editor's @ picker, so it becomes a real reference to that MCP server tool. The tools must be active in Staging to appear there.
- Don't add curly brackets or em dashes: Netomi doesn't support them in these fields.
- Click Validate, then Move to Staging. The demo runs against Staging.

## Playbook title
Book a technician visit

## Task
Book a technician visit

## Trigger Condition
Trigger when the customer wants a technician to come out, asks to book, schedule, or arrange a repair visit, or describes an appliance problem and wants someone to fix it. Also trigger while the customer is choosing between technicians or times that were offered.
Do not trigger when the customer only asks what an error code or symptom means, asks about replacement parts, prices, or stock, or wants to change or cancel a visit that is already booked.

## Procedure

Step 1 - Collect the visit details
- You need four details: the customer's ZIP code, the appliance brand, the issue, and the customer's name.
- If the customer also asked what an error code or symptom means, answer that briefly from the knowledge base first.
- Ask only for the details that are still missing, in one message.
- Make sure the ZIP code is usable before proceeding. If it is clearly incomplete or malformed (for example, it does not have 5 digits), ask the customer to provide it again.
- If the customer gives an appliance type, a model, or unclear wording instead of the appliance maker, ask a follow-up question to get the brand before proceeding.
- Do not proceed until you have all four details.
Step 1.1 - As soon as you have all four details, proceed to Step 2 in the same turn. Do not ask the customer to confirm details they already gave, and do not ask more questions about the issue.
Step 1.2 - If the customer asks to speak to a human agent, proceed to Step 7.

Step 2 - Search for technicians
- Invoke @search_technicians with the ZIP code, the brand, and the issue in the customer's own words.
- Never tell the customer you are looking something up without invoking the tool in that same turn.
- The result lists only technicians who have open times.
- Do not tell the customer anything about availability until you have the @search_technicians result.
Step 2.1 - If the result lists one or more technicians, proceed to Step 3.
Step 2.2 - If the result lists no technicians, tell the customer that no technician who serves their ZIP code and brand has an open time, then proceed to Step 7.
Step 2.3 - If the call returns an error and no result, proceed to Step 7.

Step 3 - Offer the technicians and times
- List every technician in the result in rank order, rank 1 first, each with their rating and their open times exactly as written in the result.
- Ask which technician and which time the customer wants.
- If the customer does not clearly choose one offered technician and one offered time, or names an option that was not offered, ask them to choose from the offered options, and stay in Step 3.
- Do not book anything yet. Do not proceed until the customer has clearly picked one offered technician and one offered time.
Step 3.1 - As soon as the customer picks a technician and a time, proceed to Step 4 in the same turn.
Step 3.2 - If the customer changes their mind before anything is booked, use their latest choice and proceed to Step 4.
Step 3.3 - If the customer asks to speak to a human agent, proceed to Step 7.

Step 4 - Book the visit
- Invoke @book_slot with the technician's name and the time, each exactly as written in the tool result you offered them from, the same ZIP code, brand, and issue you searched with, and the customer's name.
- You book visits yourself. Do not transfer the customer to a human agent to make a booking.
- Do not tell the customer that the visit is booked, or that it can't be booked, until you have the @book_slot result.
Step 4.1 - If booked is true, proceed to Step 5.
Step 4.2 - If booked is false and the reason is technician_not_eligible, proceed to Step 7.
Step 4.3 - If booked is false, the reason is time_taken or choose_again, and open_times lists one or more times, proceed to Step 6.
Step 4.4 - If booked is false, the reason is time_taken or choose_again, and open_times is empty, tell the customer this technician has no other open times, then return to Step 2. The new result will not include this technician, because it lists only technicians who have open times.
Step 4.5 - If the call returns an error and no result, or booked is false with any reason other than technician_not_eligible, time_taken, or choose_again, proceed to Step 7.

Step 5 - Confirm the booking
- Inform the customer "Your visit is booked with [technician] on [time]."
→END PROCESS HERE

Step 6 - Offer the technician's other times
- A result with booked false is not an error. Use this step only when the time the customer picked can't be booked and open_times lists one or more other times for the same technician.
- If the reason is time_taken, apologize briefly that someone else just booked that time.
- Offer the times in open_times, with the same technician, and ask which one the customer wants.
- If the customer does not clearly choose one offered time, or names a time that was not offered, ask them to choose from the offered times, and stay in Step 6.
- Stay with this technician unless the customer asks for a different one.
Step 6.1 - When the customer picks one of these times, return to Step 4.
Step 6.2 - If the customer wants a different technician instead, return to Step 2.
Step 6.3 - If the customer asks to speak to a human agent, proceed to Step 7.

Step 7 - Transfer to a human agent
- Tell the customer you are transferring them to a human agent, and restate their ZIP code, brand, and issue (whatever you have so far).
→END PROCESS HERE

## Enforcement Summary
- ALWAYS invoke @search_technicians in the same turn you have the four details.
- ALWAYS invoke @book_slot as soon as the customer picks a technician and a time.
- NEVER transfer a customer to a human agent to make a booking. Transfer ONLY in the cases that lead to Step 7.
- NEVER tell the customer the result of a search or a booking before you have the tool result.
- NEVER tell the customer a visit is booked unless @book_slot returned booked true.
- A result with booked false is NEVER a tool-call error. ALWAYS route it by its reason, exactly as Steps 4.2 to 4.5 say.
- ONLY offer technicians and times that a tool result returned.
