CREATE TABLE IF NOT EXISTS ranks
(
    level        smallint PRIMARY KEY,
    display_name varchar(50) UNIQUE NOT NULL,
    chat_format  varchar(150)       NOT NULL
);

--Make trigger
INSERT INTO ranks
VALUES (10, 'Player', 'Player:')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS players
(
    id       serial PRIMARY KEY,
    nick     varchar(17) UNIQUE  NOT NULL,
    password varchar             NOT NULL,
    email    varchar(75) UNIQUE,
    rank     smallint DEFAULT 10 NOT NULL REFERENCES ranks ON UPDATE SET DEFAULT
);

--Make trigger
INSERT INTO players
VALUES (1, 'unknown.', '12345', NULL, 10)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS servers
(
    id           smallserial PRIMARY KEY,
    bungee_name  varchar(30) UNIQUE NOT NULL,
    display_name varchar(30) UNIQUE NOT NULL
);

--Make triggers
INSERT INTO servers
VALUES (1, 'bungeecord', 'Sieć'),
       (2, 'Website', 'Strona')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS active_ranks
(
    player     int REFERENCES players ON DELETE CASCADE,
    server     smallint REFERENCES servers ON DELETE CASCADE,
    rank       smallint REFERENCES ranks ON DELETE CASCADE,
    start      int NOT NULL,
    expiration int NOT NULL,
    PRIMARY KEY (player, server, rank)
);

CREATE TABLE IF NOT EXISTS permissions
(
    id         serial PRIMARY KEY,
    server     smallint    NOT NULL REFERENCES servers ON DELETE CASCADE,
    rank       smallint    NOT NULL REFERENCES ranks ON DELETE CASCADE,
    permission varchar(75) NOT NULL
);

CREATE TABLE IF NOT EXISTS bans
(
    id         serial PRIMARY KEY,
    server     smallint      NOT NULL REFERENCES servers ON DELETE CASCADE,
    recipient  int           NOT NULL REFERENCES players ON DELETE CASCADE,
    giver      int DEFAULT 1 NOT NULL REFERENCES players ON DELETE SET DEFAULT,
    reason     varchar(300)  NOT NULL,
    start      int           NOT NULL,
    expiration int --CHECK ( start < expiration OR expiration IS NULL ) --TODO is this check good?
);

CREATE TABLE IF NOT EXISTS ip_bans
(
    ip_address varchar(15) PRIMARY KEY,
    giver      int DEFAULT 1 NOT NULL REFERENCES players ON DELETE SET DEFAULT,
    reason     varchar(300)  NOT NULL,
    start      int           NOT NULL
);

CREATE TABLE IF NOT EXISTS bans_history
(
    id                int PRIMARY KEY,
    server            smallint      NOT NULL REFERENCES servers ON DELETE CASCADE,
    recipient         int           NOT NULL REFERENCES players ON DELETE CASCADE,
    giver             int DEFAULT 1 NOT NULL REFERENCES players ON DELETE SET DEFAULT,
    ban_reason        varchar(300)  NOT NULL,
    start             int           NOT NULL,
    target_expiration int,-- CHECK ( start < target_expiration ),

    real_expiration   int           NOT NULL,
    expiration_type   smallint      NOT NULL,
    expiration_reason varchar(300),
    modder            int           REFERENCES players ON DELETE SET NULL,
    new_ban           int
);

CREATE TABLE IF NOT EXISTS ip_bans_history
(
    id                serial PRIMARY KEY,
    ip_address        varchar(15)   NOT NULL,
    giver             int DEFAULT 1 NOT NULL REFERENCES players ON DELETE SET DEFAULT,
    reason            varchar(300)  NOT NULL,
    start             int           NOT NULL,

    expiration        int           NOT NULL,
    expiration_reason varchar(300),
    modder            int           REFERENCES players ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS activity_history
(
    id         serial PRIMARY KEY,
    player     int         NOT NULL REFERENCES players ON DELETE CASCADE,
    time       int         NOT NULL,
    status     smallint    NOT NULL,
    ip_address varchar(15) NOT NULL
);

CREATE TABLE IF NOT EXISTS ip_blockades
(
    id         serial PRIMARY KEY,
    player     int                   NOT NULL REFERENCES players ON DELETE CASCADE,
    time       int                   NOT NULL,
    ip_address varchar(15)           NOT NULL,
    to_check   boolean DEFAULT false NOT NULL
);

--Stored procedures

CREATE OR REPLACE FUNCTION ban_player(
    _recipient varchar(17),
    _giver varchar(17),
    _server varchar(30),
    _reason varchar(300),
    _start int,
    _expiration int
) RETURNS VOID
AS
$$
DECLARE
BEGIN
    INSERT INTO bans
    VALUES (
               DEFAULT,
               (SELECT id FROM servers WHERE lower(bungee_name) = lower(_server)),
               (SELECT id FROM players WHERE lower(nick) = lower(_recipient)),
               (SELECT id FROM players WHERE lower(nick) = lower(_giver)),
               _reason,
               _start,
               _expiration
           );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION ban_ip_address(
    _ip_address varchar(15),
    _giver varchar(17),
    _reason varchar(300),
    _start int
) RETURNS VOID
    LANGUAGE plpgsql AS
$$
BEGIN
    INSERT INTO ip_bans
    VALUES (
               _ip_address,
               (SELECT id FROM players WHERE lower(nick) = lower(_giver)),
               _reason,
               _start
           );
END
$$;

CREATE OR REPLACE FUNCTION unban_player (
    _recipient_name varchar(17),
    _server_name varchar(30),
    _real_expiration int,
    _expiration_type smallint,
    _expiration_reason varchar(300),
    _modder varchar(17),
    _new_ban int = NULL
) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    removing_ban_id int;
BEGIN
    --Check if modder exists
    IF NOT EXISTS(SELECT 1 FROM players WHERE lower(nick) = lower(_modder)) AND NOT NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOMOD',
                MESSAGE = 'Modder does not exists!',
                HINT =  'Insert modder into the players table, eventually you can type NULL instead if modder is not important.';
    END IF;

    --Move ban to history_ban
    INSERT INTO bans_history
    SELECT bans.*, _real_expiration, _expiration_type, _expiration_reason, M.id, _new_ban
    FROM bans
             INNER JOIN servers S on (S.id = bans.server AND lower(S.bungee_name) = lower(_server_name))
             INNER JOIN players R on (R.id = bans.recipient AND lower(R.nick) = lower(_recipient_name))
             LEFT JOIN players M on lower(M.nick) = lower(_modder)
    ORDER BY bans.id DESC
    LIMIT 1
    RETURNING id
        INTO removing_ban_id;

    IF removing_ban_id IS NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOBAN',
                MESSAGE = 'Ban does not exists (Player was not banned)!';
    END IF;

    --Delete ban from bans table
    DELETE FROM bans WHERE id = removing_ban_id;
END
$$;

CREATE OR REPLACE FUNCTION unban_player_last_own_ban(
    _recipient_name varchar(17),
    _giver_name varchar(17),
    _server_name varchar(30),
    _real_expiration int,
    _expiration_type smallint,
    _expiration_reason varchar(300),
    _modder varchar(17),
    _new_ban int = NULL
) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    removing_ban_id int;
BEGIN
    --Check if modder exists
    IF NOT EXISTS(SELECT 1 FROM players WHERE lower(nick) = lower(_modder)) AND NOT NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOMOD',
                MESSAGE = 'Modder does not exists!',
                HINT =  'Insert modder into the players table, eventually you can type NULL instead if modder is not important.';
    END IF;

    INSERT INTO bans_history
    SELECT bans.*, _real_expiration, _expiration_type, _expiration_reason, M.id, _new_ban
    FROM bans
             INNER JOIN servers S on (S.id = bans.server AND lower(S.bungee_name) = lower(_server_name))
             INNER JOIN players R on (R.id = bans.recipient AND lower(R.nick) = lower(_recipient_name))
             INNER JOIN players G on (G.id = bans.giver AND lower(G.nick) = lower(_giver_name))
             LEFT JOIN players M on lower(M.nick) = lower(_modder)
    ORDER BY bans.id DESC
    LIMIT 1
    RETURNING id
        INTO removing_ban_id;

    IF removing_ban_id IS NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOBAN',
                MESSAGE = 'Ban does not exists (Player was not banned, or was not banned by you)!';
    END IF;

    --Delete ban from bans tableVOID
    DELETE FROM bans WHERE id = removing_ban_id;
END
$$;

CREATE OR REPLACE FUNCTION get_last_expiring_ban(
    _recipient varchar(17),
    _server varchar(30)
) RETURNS TABLE
          (
              id int,
              giver varchar(17),
              reason varchar(300),
              start int,
              expiration int
          )
    LANGUAGE plpgsql AS
$$
BEGIN
    RETURN QUERY
        SELECT B.id, G.nick, B.reason, B.start, B.expiration
        FROM bans AS B
                 INNER JOIN servers S on (B.server = S.id AND lower(S.bungee_name) = lower(_server))
                 INNER JOIN players R on (B.recipient = R.id AND lower(R.nick) = lower(_recipient))
                 INNER JOIN players G on B.giver = G.id
        ORDER BY B.expiration DESC
        LIMIT 1;
END
$$;

CREATE OR REPLACE FUNCTION unban_expired_bans(
    _time int,
    _reason varchar(300)
) RETURNS integer AS
$$
BEGIN
    WITH move_expired_bans
             AS (
            INSERT INTO bans_history
                SELECT B.*, _time, 0, _reason, NULL, NULL
                FROM bans AS B
                WHERE expiration <= _time
                RETURNING id
        )
    DELETE FROM bans WHERE id IN (SELECT id FROM move_expired_bans);

    RETURN (
        SELECT expiration
        FROM bans
        ORDER BY expiration DESC
        LIMIT 1);
END
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION unban_ip_address (
    _ip_address varchar(15),
    _expiration int,
    _reason varchar(300),
    _modder varchar(15)
) RETURNS VOID
    LANGUAGE plpgsql AS
$$
DECLARE
    _removing_ban varchar(15);
BEGIN
    --Check if modder exists
    IF NOT EXISTS(SELECT 1 FROM players WHERE lower(nick) = lower(_modder)) AND NOT NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOMOD',
                MESSAGE = 'Modder does not exists!',
                HINT =  'Insert modder into the players table, eventually you can type NULL instead if modder is not important.';
    END IF;

    INSERT INTO ip_bans_history (ip_address, giver, reason, start, expiration, expiration_reason, modder)
    SELECT B.ip_address, B.giver, B.reason, B.start, _expiration, _reason, M.id
    FROM ip_bans AS B
             LEFT JOIN players AS M ON (lower(M.nick) = lower(_modder))
    WHERE B.ip_address = _ip_address
    RETURNING ip_address
        INTO _removing_ban;

    IF _removing_ban IS NULL THEN
        RAISE EXCEPTION
            USING
                ERRCODE = 'NOBAN',
                MESSAGE = 'Ban does not exists (IP address was not banned)!';
    END IF;

    DELETE FROM ip_bans
    WHERE ip_address = _removing_ban;
END
$$;