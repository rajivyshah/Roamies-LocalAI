import assert from 'node:assert/strict';
import { QUESTIONS, opener, openNote, answerNote, answerTurn, wantsSkip, endsChat, questionIn, splitTurn, plain, stripNote } from '../intro.mjs';

assert.equal(QUESTIONS, 4);
assert.match(opener('Ken'), /^Hi Ken, I'm Roamie!.*four quick questions\. What are you working on these days\?$/);
assert.match(opener('Ken', 'Sarah'), /^Hi Ken, I'm Sarah! /, "each look says its own name");
assert.ok(!/[—–]| - /.test(opener('Ken')), 'no dashes in the opener');
assert.match(openNote('Ken'), /word for word.*"\[wave\] Hi Ken/s);

// Answers 1 and 2 get a follow-up question, 3 gets the fixed AI question, 4 wraps up (a memory pass saves the facts).
assert.match(answerNote(1, 'Ken'), /answer 1 of 4.*ONE easy question.*2 free questions left/s);
assert.match(answerNote(1, 'Ken'), /relaxed get-to-know-you chat/, 'the rules ride with the first answer');
assert.match(answerNote(2, 'Ken'), /1 free question left.*actual thing/s);
assert.match(answerNote(3, 'Ken'), /last one.*AI helpers/s);
for (let n = 1; n <= QUESTIONS; n++) assert.ok(!/remember_fact|tools? this chat, except/.test(answerNote(n, 'Ken')), `answer ${n}: no fact tool any more`);
assert.match(answerNote(4, 'Ken'), /LAST answer.*Do not ask anything more.*\[wave\]/s);
// The memory pass reads their words, not the app's notes; the opener note has none.
assert.equal(stripNote(answerTurn(2, 'Ken', 'I make videos\n\nand courses')), 'I make videos\n\nand courses');
assert.equal(stripNote(openNote('Ken')), '');
assert.equal(stripNote('[Mon] what time is it'), '[Mon] what time is it', 'ordinary messages untouched');
assert.match(answerTurn(2, 'Ken', 'I make videos'), /\n\nKen said: I make videos$/);

for (const s of ['skip', 'Skip.', 'stop', 'stop asking', "let's skip", 'skip this', 'please skip', 'cancel', 'skip for now!']) assert.ok(wantsSkip(s), s);
// Real answers that only look like opting out go to the model instead.
for (const s of ['nope', 'no', 'no thanks', 'pass', 'not now', 'later', 'I build apps', 'I stop by the gym after work', 'skipping rope is my hobby', 'later this year I launch', '']) assert.ok(!wantsSkip(s), s);
assert.ok(endsChat('Sure, we can stop. I am here whenever you need me.'), 'no question: the chat is over');
assert.ok(!endsChat('Nice! What do you use most?'));
assert.match(answerNote(1, 'Ken'), /SKIPPING.*no question.*REQUESTS.*save nothing/s);
assert.match(answerNote(2, 'Ken'), /want to stop, one short line with no question/);
assert.match(answerNote(3, 'Ken'), /want to stop, one short line with no question/);

assert.equal(questionIn('[wave] Hi Ken! I make things. What are you working on these days?'), 'What are you working on these days?');
assert.equal(questionIn('Videos, nice. What kind of videos do you make? Could be tutorials, vlogs, or something else entirely.'), 'What kind of videos do you make?');
assert.equal(questionIn('No question here.'), 'Type your answer…');
assert.equal(questionIn(`${'a'.repeat(120)}?`), 'Type your answer…', 'too long for the box');
assert.equal(questionIn('VS Code, nice. 😄 What\'s the actual thing you\'re going for right now? Could be X.'), "What's the actual thing you're going for right now?", 'no emoji in front');
assert.equal(questionIn("100k by summer, love it! Okay, last one: have you used AI helpers before, like ChatGPT, Claude, Gemini, an AI that does things on your computer, or none yet?"), 'Have you used AI helpers before?', 'long question cut to its core');
// The guide window shows the reaction, the question as the heading, and the nudge after it.
assert.deepEqual(splitTurn("[wave] Hi Ken, I'm BitJarvis! I've got four quick questions. What are you working on these days?"),
  { lead: "Hi Ken, I'm BitJarvis! I've got four quick questions.", question: 'What are you working on these days?', hint: '' });
assert.deepEqual(splitTurn('[warm] Night shifts and exam prep, wow. What does a normal week look like? Could be the hospital, Anki, or something else entirely.'),
  { lead: 'Night shifts and exam prep, wow.', question: 'What does a normal week look like?', hint: 'Could be the hospital, Anki, or something else entirely.' });
assert.deepEqual(splitTurn('Okay, last one: have you used AI helpers before?'), { lead: '', question: 'Okay, last one: have you used AI helpers before?', hint: '' });
assert.deepEqual(splitTurn('Thanks Ken! Passing your boards is a great place to start.'), { lead: 'Thanks Ken! Passing your boards is a great place to start.', question: '', hint: '' });
assert.equal(plain('[hype] [chuckling] Nice one! [break] Go.'), 'Nice one! Go.');
assert.ok(endsChat('[warm] Sure, we can stop [chuckling].'), 'cues are not questions');
console.log('intro tests: passed');
// The welcome tour: plain draw beats that pass the draw tool's checks, with a medal only when there's a goal.
{
  const { tourBeats, goalFrom } = await import('../intro.mjs');
  const { DrawArgs, checkDraw } = await import('../draw.mjs');
  assert.equal(goalFrom([{ text: 'Is a YouTuber' }, { text: 'Wants to launch a course by March' }]), 'Wants to launch a course by March');
  assert.equal(goalFrom([{ text: 'Likes coffee' }]), null);
  const withGoal = tourBeats('Ken', 'Roamie', 'Wants to launch a course by March');
  const without = tourBeats('Ken', 'Roamie', null, { mac: false });
  for (const beats of [withGoal, without]) { assert.ok(DrawArgs.safeParse({ beats }).success, 'the tour fits the draw schema'); assert.deepEqual(checkDraw({ beats }), []); }
  assert.equal(withGoal.at(-1).marks[0].kind, 'medal');
  assert.ok(!without.some((b) => b.marks.some((m) => m.kind === 'medal')), 'no goal, no medal');
  assert.ok(withGoal.slice(0, 3).every((b) => b.marks[0].kind === 'ticket' && b.marks[0].action?.do === 'ask'), 'each ticket has a button that asks');
  assert.match(without[0].marks[0].action.value, /wallpaper/, 'no words-on-screen how-to off the Mac');
  console.log('tour tests: passed');
}
// The capability showcase: fixed beats that pass the draw tool's checks, one card per listed capability, in order.
{
  const { showcaseBeats, SHOWCASE } = await import('../intro.mjs');
  const { DrawArgs, checkDraw } = await import('../draw.mjs');
  const beats = showcaseBeats('Ken', 'Sarah');
  assert.ok(DrawArgs.safeParse({ beats }).success, 'the showcase fits the draw schema');
  assert.deepEqual(checkDraw({ beats }), [], 'the showcase passes the draw checks (the molecule parses)');
  assert.equal(beats.length, SHOWCASE.length + 1, 'one beat per capability, then a wrap-up');
  assert.deepEqual(beats.slice(0, -1).map((b) => b.marks[0].kind), ['card', 'graph', 'timeline', 'molecule', 'model', 'list']);
  assert.ok(beats[0].marks[0].sources.length, 'the web search card shows where it came from');
  assert.match(beats.at(-1).say, /Sarah/, 'the wrap-up uses the look\'s name');
  assert.ok(!beats.some((b) => b.marks.some((m) => m.action || m.at)), 'nothing to click and nothing on the screen to find');
  console.log('showcase tests: passed');
}
