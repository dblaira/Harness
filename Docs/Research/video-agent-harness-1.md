![Thumbnail (1920x1080)](https://i.ytimg.com/vi/mY3bR9qjZr4/maxresdefault.jpg)
# [You Can Learn AI Agent Memory System In 12 Min | Semantic & Episodic Memory, RAG, Vector Database](https://www.youtube.com/watch?v=mY3bR9qjZr4)

**Visibility**: Public
**Uploaded by**: [Sean‘s AI Stories](https://www.youtube.com/@SeanAIStories)
**Uploaded at**: 2026-06-19
**Published at**:
**Length**: 12:05
**Views**: 13577
**Likes**: 662
**Category**: Science & Technology

## Description

```
If you've used ChatGPT or Claude for a while, you've already been using an AI memory system without realizing it. It knows who you are, what you asked last week, sometimes even what your company does. In this one I draw the whole thing out on a whiteboard, step by step, so you can design your own even if you don't come from a technical background.

Here's what we cover:
- Working memory (the context RAM): your prompt, chat history, and system prompt, and why every session is wiped unless you save it
- Procedural memory: how the agent should behave, its rules and skills, usually a plain file like a SKILL.md
- Semantic memory: durable facts and user profiles in a vector database, pulled back with RAG so you only fetch the few most relevant pieces
- Episodic memory: a dated log of past chats and events on a timeline
- The consolidation gate and a cheaper summarizer agent that distills it all into durable facts

That last part is the trick most people miss. You don't search the giant episodic log every time, you wait until enough chats pile up, then a cheaper model distills them into a handful of facts. It's why your ChatGPT memory stays short but somehow always up to date.

You can build anything. You can learn anything. 💪

Timeline
00:00 Intro
00:45 What is a User Prompt
01:14 Working Memory (Context RAM)
02:55 The AI Agent Session is Ephemeral
03:31 The Three Memory Pillars
03:42 Procedural Memory (Skill.md)
04:47 Semantic Memory (Durable Facts, User Profile)
05:29 RAG and Top-K Search
07:00 Episodic Memory (Dated Events, Past Chats)
08:31 Saving Messages to Memory
08:51 How ChatGPT and Claude Memory Works
10:08 The Consolidation Gate
11:21 Summarizer Agent (Distill Into Facts)
11:27 Recap

Launch Full-Stack App Template: https://github.com/ShenSeanChen/launch-mvp-stripe-nextjs-supabase
My AI Agent Startup AutoManus.io is an AI sales lead manager for made-to-order product sales. We embed directly where conversations happen (WhatsApp, email, web chat) to capture inbound, automate follow‑ups, and kill CRM busywork; live with 4 pilots and 2 contracts in motion, pre‑seed backed by Character VC. Focused on US/UK/Germany, raising to expand engineering and scale deployments.

☕️ Buy me a coffee: https://buy.stripe.com/5kA176bA895ggog4gh
- X: https://x.com/ShenSeanChen
- Sean's Discord: https://discord.gg/tvECErKcFr
- AutoManus Discord: https://discord.gg/5HhcNjCR
- LinkedIn: https://linkedin.com/in/shen-sean-chen
- Github Link: https://github.com/ShenSeanChen
- Instagram: https://www.instagram.com/sean_ai_stories

Sub Count when launched: 12,342

Top Github Repos
- LaunchMVP NextJS,Supabase,Stripe (1014 stars): https://github.com/ShenSeanChen/launch-mvp-stripe-nextjs-supabase
- ReactNextJSTips (114 stars): https://github.com/ShenSeanChen/yt-react-nextjs-tips
- DeepResearchAgentBackend (69 stars): https://github.com/ShenSeanChen/yt-DeepResearch-Backend
- SupabaseTipsKanban (64 stars): https://github.com/ShenSeanChen/yt-supabase-tips-kanban
- RAGVectorDB (54 stars): https://github.com/ShenSeanChen/yt-rag
- KimiK2Claude (36 stars): https://github.com/ShenSeanChen/yt-kimi-k2-claude
- DeepResearchAgentFrontend (32 stars): https://github.com/ShenSeanChen/yt-DeepResearch-Frontend
- AgenticRAG (13 stars): https://github.com/ShenSeanChen/yt-agentic-rag

You Can Build Anything Playlist (Full-Stack Dev Without CS Degrees)
- Core7: 95% React/NextJS Use Cases https://www.youtube.com/watch?v=vZzFlAjz4rA&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=16
- Core6: 95% Supabase Use Cases https://www.youtube.com/watch?v=Pnoq2tIif3s&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=15
- Core5: StripeNextJSSupabase https://www.youtube.com/watch?v=ad1BxZufer8&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=8
- Core4: AuthSupabaseGoogle https://www.youtube.com/watch?v=AZAU3ClAWWE&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=6
- Core3: FastapiGCPPro https://www.youtube.com/watch?v=u3sfqpzzo-U&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=5
- Core2: SupabaseHero https://www.youtube.com/watch?v=V0kmgkyPsVQ&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=4
- Core1: LaunchAnApp https://www.youtube.com/watch?v=iQ2izvGG4tQ&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=3
- Launch WhereToMeet w/ GoogleMaps, Calendar, Supabase, Cursor: https://www.youtube.com/watch?v=5xMjX1QxGUY&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR&index=2
- Launch EncourageMe w/ Cursor, Supabase, Vercel https://www.youtube.com/watch?v=hnvL4xa2DHA&list=PLE9hy4A7ZTmpGq7GHf5tgGFWh2277AeDR
```

## Transcript

Hey everyone, this is Shawn. So, today I
want to explain to you what an AI agent
memory system looks like, and it's very
important to understand how memory works
these days. Because if you have been
using tools like ChatGPT or Claude, or
code, you're probably already using a
memory system without even realizing it.
For example, when you ask your AI tool
about who you are and the question that
you asked them for the past week, they
all know what's going on. And if you're
an AI builder or startup founder,
sometimes they even remember what your
company is without you needing to
explain it. So, in this video I want to
explain to you the essential part of how
does this exactly work? And I'm going to
walk you through this system design you
can see on the screen step-by-step, so
that you will understand what matters in
this kind of system design, and also
what will help you for efficient token
usage in a memory system for AI agents.
Let's get started. So, when we talk to
ChatGPT or Claude or anything, the first
thing you're going to do is going to
you're going to ask a question, which in
our language is called a user prompt,
okay? A prompt is basically something
that you send to to a chatbot and be
like, "Hey, what's the weather like
today? How do I build an app? How do I
understand Einstein's theory?" So, we
might think that we're asking the
question to this pink bubble, which is
an LLM, which is a Q&A agent, which
allows you to ask questions and answer
your questions, and then you will get a
reply. In between that, there's some
more steps that's happening before that,
okay? So, this question will firstly
flow into this thing called a working
memory or a context RAM. What does that
mean? It means that instead of asking a
simple question such as, "What does my
company do?" in which case the large
language model might not even remember
or don't even know, it needs to have a
working memory that either includes some
information from the internet or from
the current context itself or from some
databases that you would that you stored
such information previously. And then
this working memory also needs to be fed
with something called a current chat
history and a system prompt. The chat
history is basically everything you have
talked about in a in a conversation with
AI, okay? That's easy to understand. For
system prompt is basically a role-play.
For example, if you want AI to be able
to respond to you like Elon Musk, then
you need to put in the system prompt
that, "Hey, you're Elon Musk. You must
talk to me like Elon Musk." So, the user
question, the user prompt, the current
chat history, and the system prompt are
the basic components that will be fed
into this working memory or the current
context so that your Q&A agent will be
able to understand, "Okay, here's the
entire context. I'm going to process
these information before I send this
user a reply." But, what if we need more
than just the current chat history?
Okay, what if we need something else?
Let's say you're setting up an agent to
allow your customers to talk to you and
ask any questions about your products,
about the deal that you're talking
about. The customer might might be
asking you something related to the
quality of your products, related to
your previous conversations, a follow-up
question, these kind of things. All
right, and the current chat history is
all the history that happened in that
e-commerce app. And the system prompt is
probably like, "Oh, you are a bot that
will take care of all of my customers on
this e-commerce site." And the
conversation happening here is called an
AI agent session. And this session is
ephemeral, which means that nothing here
will get saved unless you manually save
them in a database cuz there's no
database here yet. We're literally just
making an LLM call right here. Well, you
could argue that the current chat
history has a bit of memory, but that's
just happening in this current
conversation. This current session does
not know anything about your product
stocks, about you know, your previous
purchase history, your customers' taste,
um anything you have argued about, any
complaints in the past, these kind of
things. Okay. That's why we need to
build up on this working memory and give
it more rich information and make it
efficient as well. So, there are three
main pillars that will make this working
memory more complete. And they are
procedural memory, semantic memory, and
episodic memory. I'll explain them one
by one. A procedural memory is basically
how the agent should be behaving. It's
usually related to how they should act.
And also, if you're familiar, uh you
could write some skills to teach agent
to do some repeated tasks. For example,
it could be something like if you
realize that the customer is really
angry, you should answer them politely
and always apologize. This is a skill
that your agent should learn and there's
no memory about this thing, right? You
can think of this as like a habit you
want to teach to your employee to behave
in a certain way or teach your kids,
right? To behave in a certain way. And
it's just a procedure, right? This is
how you react when such a situation
happens. And they are usually saved in
files or text and you know, for skills
can save them as a markdown file. All
right? So, I'm going to connect this to
the working memory and this is usually
inputted as a skill.md markdown file.
Okay? And semantic memory and episodic
memory are slightly different. They're
actually saved not in files but we would
call vector stores. And these vector
stores will feed information into this
memory that will be plugged in to the
working memory. Let's dive a little bit
deeper into what these memories actually
mean, okay? So, for semantic memory,
it's basically saving things like
durable facts or user profile. Let's say
I start a new store online today and if
I just ask ChatGPT who what my products
are, ChatGPT will have no idea who you
are. Well, if they do have some idea of
who you are, say you if you're Walmart,
then that means you're already famous,
okay? Then their models has already
trained on you or they can search on the
internet to find about you, all right?
But in your case, because the
foundational large language model does
not know who you are, you need to save
some durable facts or the profile of
your company or about yourself in a
database so that when one of your
customers is asking a question about a
certain product, your agent will be able
to understand where to fetch that
information. And this is a process we
call RAG, which is retrieval augmented
generation. And normally it uses a top
case search method. I have a dedicated
video about retrieval augmented
generation on my channel, feel free to
watch them. But basically RAG is
something that will allow the AI agent
to have access to and also be able to
select and fetch the most relevant
information related to your questions,
okay? Why is selectively fetching so
important? It's because if you run a
company for 10 years, let's say, your
database could be really huge. You could
have like gigantic amount of images or
text or documentations about a company.
You don't want to feed the whole thing
into the LLM because firstly, that would
be very expensive, and secondly, that's
probably not feasible, okay? These days,
I think the context window for most LLMs
is roughly 1 million tokens. Right? If
you go beyond that, good luck with that,
but you don't want to overload your LLMs
because that also makes things much
slower and not accurate anymore. So, you
want something to smartly fetch
information for you, and this method is
called RAG. You can watch my previous
video to understand a bit better about
what RAG means. But here is basically
just helping you to fetch the static and
durable facts about your company, what
products you're selling, who you are,
what kind of branding you have, what
kind of ways do you put yourself out
there in front of customers, okay? These
things don't change normally. Or the
facts could be like, oh, who this
customer is, like if they message me
very often, I want to remember who they
are, right? Otherwise, it sounds like
you don't really care about your
customers. I'm going to explain how
we're going to make semantic memory to
also remember your customer side as well
in a bit, okay? And then we're covering
the episodic memory, which is also
stored in a vector store. Again, a
vector store is a embedded list of
arrays or numbers that is representing
all the text cuz remember, computers
cannot process text or documents. It can
only process numbers. So, how how AI is
understanding our world is basically
it's turning every single word into a
list of numbers, and then it's going to
do some similarity search, which is
basically RAG. RAG, again, it's doing
the top K search, and if K is five, then
it's looking for the top five most
relevant pieces of information from the
vector store to feed into answering this
question from the user. But the main
difference between an episodic memory
and a semantic memory is that the
episodic memory is recording the dated
events or activities that happened. It's
like a timeline with like everything
that happened has a time on it or it's
just a past chat history. Remember we
mentioned that in this box, this AI
agent session, everything is going to be
gone after the conversation is is gone,
right? So So we're going to save this
conversation, the current chat history,
into the episodic memory
later so that it has the entire record
of the previous conversations related to
this agent activities with their users.
Well, the examples here for selling
items online could be that, you know,
you're you're storing like who's
purchasing what items on what day and
then and when was the item delivered
and when was the last time somebody
filed a complaint for your service,
something like that, okay? So we're
going to need to add an arrow here to
link the reply to this database and this
is basically saving
the messages or actually
activities as well, okay? So that this
episodic memory is constantly being
updated. It's basically a log of all
previous history. So here's the fun
part. If you have been using ChatGPT or
Claude and you use their memories, you
will realize that sometimes you can edit
the memories for yourself and you
realize that the memories are not very
long, but then they're constantly being
like updated. For example, it remembers
that I'm building a company that is
working on certain type of problem. I
don't need to explain anything, but
sometimes we do a small pivot and we
talked about it in the in our
conversations and then the memory just
remembered that, okay? For an efficient
agent memory system to work, you don't
want the AI agent to always search these
kind of information from an episodic
memory because that's just a huge
database about everything that happened
in the past. You want some kind of
durable summarized facts that you think
is uh very important for AI to know,
okay? So that's why ChatGPT and Claude
and all these AI agents are all doing
something similar, which is that it's
summarizing at a certain frequency,
which is not too frequent, of all of
these
activities that happened into the
semantic memory, so that the facts about
you, about your company, about
everything is condensed and saved
properly for future retrievals, okay?
And this is actually very smart because
it not only saved a lot of token usage
every single time, and also it's making
your tools much faster. But let's pause
here for 1 second.
If we summarize every single bit of new
activities into the semantic memory,
then that sounds like we're just saving
the information twice. What's the point
of having a durable facts anyways? And
that brings us into this concept of a
gate, which is we only consolidate after
a certain number of chats. It could be
20 conversations, it could be, you know,
100 activities, could be anything, okay?
So, in order for these system to work
together, we need a system that will,
you know, do some consolidation after
certain number messages, and then we
feed that into the summarizer agent.
And then the summarizer agent will then
summarize the information into the
semantic memory, and we call this the
steel
into facts. So, congratulations, this is
pretty much it. You have built up an
entire memory system that is, in my
opinion, quite modern in these days
context, and it should be embedded in
any AI applications that we're building
these days, because it's so easy for
users to engage with an AI agent, and
it's so easy to build software.
But then what happens is that the
database is just exploding if you're
recording all these activities. So, we
need to figure out a way to very
efficiently not only record the data,
but also, you know, summarizing the
data, and then turn them into sort of
some core memory, which is semantic, and
then some episodic memory, which is um
just a timeline of list of things. And
at the same time, you can define the
best practices of how the agent should
behave in a certain task, okay? Which is
what skills is about. I also made a
video about agent skills, agent teams in
the past, feel free to check them out.
But overall, I believe this is a very
complete way to understand what an AI
agent system should be performing with a
memory that will be added as a context
layer on top of the entire interaction.
I hope you enjoy this. Let me know if
you have any questions, and I'll see you
next time. Thanks.