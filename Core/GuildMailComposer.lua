local _, addon = ...

-- Fills in a Guild Mail's subject and body for one recipient, with the same
-- placeholders as Guild Greet ({name}, {main}, {mainFirst}, {mainLast},
-- {character}, {characterFirst}, {characterLast}, in any case), and checks
-- the filled-in mail against the game's limits. {character} is the
-- character the mail is addressed to.
--
-- Pure: it reads a FellowshipStore partition and a NameNormalizer, and never
-- touches the game.
local GuildMailComposer = {
    -- The game's limits on a mail's subject and body, in letters.
    SUBJECT_LETTERS = 64,
    BODY_LETTERS = 500,
    -- Every placeholder and what a mail fills it with. Case doesn't matter.
    PLACEHOLDERS = {
        { "{name}", "their alias, else their main's name" },
        { "{main}", "their main's name, even when they have an alias" },
        { "{mainFirst}", "the first part of their main's name" },
        { "{mainLast}", "the last part of their main's name" },
        { "{character}", "the character the mail is sent to" },
        { "{characterFirst}", "the first part of that character's name" },
        { "{characterLast}", "the last part of that character's name" },
    },
}
addon.GuildMailComposer = GuildMailComposer

-- The number of letters in UTF-8 `text`, as the game counts them.
function GuildMailComposer.Letters(text)
    local _, continuation = string.gsub(text, "[\128-\191]", "")
    return string.len(text) - continuation
end

-- `subject` and `body` filled in for `recipient` ({ key, name }, `name`
-- spelled as the roster does) in `partition` with `normalizer` (either may
-- be nil):
--   { subject, body, warning, names }
-- `warning` says what's over the game's limit, or is nil when the mail fits;
-- `names` is what each placeholder was filled with.
function GuildMailComposer.Compose(subject, body, recipient, partition, normalizer)
    local names = addon.GuildGreet.NamesFor(partition, normalizer, recipient.key, recipient.name)
    local mail = {
        subject = addon.GreetingLibrary.Fill(subject or "", names),
        body = addon.GreetingLibrary.Fill(body or "", names),
        names = names,
    }
    local subjectLetters = GuildMailComposer.Letters(mail.subject)
    local bodyLetters = GuildMailComposer.Letters(mail.body)
    local problems = {}
    if subjectLetters > GuildMailComposer.SUBJECT_LETTERS then
        table.insert(problems, "subject too long (" .. subjectLetters .. "/" .. GuildMailComposer.SUBJECT_LETTERS .. ")")
    end
    if bodyLetters > GuildMailComposer.BODY_LETTERS then
        table.insert(problems, "message too long (" .. bodyLetters .. "/" .. GuildMailComposer.BODY_LETTERS .. ")")
    end
    if #problems > 0 then
        mail.warning = table.concat(problems, ", ")
    end
    return mail
end

-- `subject` and `body` (a mail's text as written) filled in with `values`
-- (see Values).
function GuildMailComposer.Rebuild(subject, body, values)
    return addon.GreetingLibrary.Fill(subject or "", values), addon.GreetingLibrary.Fill(body or "", values)
end

-- What the outbox keeps of `mail` (`subject` and `body` filled in, with
-- `names`, the placeholders' values) instead of its text: the values of
-- just the placeholders `subject` and `body` use. Nil when the mail
-- doesn't rebuild word for word from them (Rebuild), so its text must be
-- kept in full.
function GuildMailComposer.Values(subject, body, mail)
    if type(subject) ~= "string" or type(body) ~= "string" or type(mail) ~= "table"
        or type(mail.names) ~= "table" or type(mail.subject) ~= "string" or type(mail.body) ~= "string"
    then
        return nil
    end
    local values = {}
    local placeholder
    for placeholder in string.gmatch(subject .. "\n" .. body, "{(%a+)}") do
        local name = string.lower(placeholder)
        if type(mail.names[name]) == "string" then
            values[name] = mail.names[name]
        end
    end
    local rebuiltSubject, rebuiltBody = GuildMailComposer.Rebuild(subject, body, values)
    if rebuiltSubject ~= mail.subject or rebuiltBody ~= mail.body then
        return nil
    end
    return values
end
