BEGIN;
CREATE TABLE IF NOT EXISTS public.exq_accounts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),username text UNIQUE NOT NULL,display_name text NOT NULL,password_hash text NOT NULL,
 failed_attempts integer NOT NULL DEFAULT 0,locked_until timestamptz,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.exq_sessions (
 token_hash text PRIMARY KEY,account_id uuid NOT NULL REFERENCES public.exq_accounts(id),expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days'
);
ALTER TABLE public.exq_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exq_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exq_accounts,public.exq_sessions FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.exq_register(p_username text,p_password text,p_name text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE uid uuid; token text;
BEGIN
 p_username=lower(trim(p_username));p_name=trim(p_name);
 IF p_username !~ '^[a-z0-9_]{3,20}$' THEN RETURN jsonb_build_object('error','Username must contain 3–20 letters, numbers or underscores.'); END IF;
 IF p_name !~ '^[A-Za-z0-9 _.-]{2,20}$' THEN RETURN jsonb_build_object('error','Display name must contain 2–20 letters, numbers or spaces.'); END IF;
 IF p_password IS NULL OR length(p_password)<8 OR octet_length(p_password)>72 THEN RETURN jsonb_build_object('error','Use a password of at least 8 characters and no more than 72 bytes.'); END IF;
 INSERT INTO exq_accounts(username,display_name,password_hash) VALUES(p_username,p_name,crypt(p_password,gen_salt('bf',10))) ON CONFLICT(username) DO NOTHING RETURNING id INTO uid;
 IF uid IS NULL THEN RETURN jsonb_build_object('error','That username is taken. Try another.'); END IF;
 token=encode(gen_random_bytes(32),'hex');INSERT INTO exq_sessions(token_hash,account_id) VALUES(encode(digest(token,'sha256'),'hex'),uid);
 RETURN jsonb_build_object('token',token,'expires_at',extract(epoch FROM(now()+interval '7 days')),'user',jsonb_build_object('id',uid,'user_metadata',jsonb_build_object('display_name',p_name),'username',p_username));
END;$$;
CREATE OR REPLACE FUNCTION public.exq_login(p_username text,p_password text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE a exq_accounts%ROWTYPE; token text;
BEGIN
 SELECT * INTO a FROM exq_accounts WHERE username=lower(trim(p_username)) FOR UPDATE;
 IF NOT FOUND THEN PERFORM crypt(p_password,gen_salt('bf',10));RETURN jsonb_build_object('error','Incorrect username or password.');END IF;
 IF a.locked_until>now() THEN RETURN jsonb_build_object('error','Too many attempts. Please try again in 15 minutes.');END IF;
 IF p_password IS NULL OR length(p_password)=0 OR octet_length(p_password)>72 OR a.password_hash<>crypt(p_password,a.password_hash) THEN
 UPDATE exq_accounts SET failed_attempts=CASE WHEN a.locked_until IS NOT NULL AND a.locked_until<=now() THEN 1 ELSE a.failed_attempts+1 END,locked_until=CASE WHEN a.failed_attempts>=4 AND (a.locked_until IS NULL OR a.locked_until>now()) THEN now()+interval '15 minutes' ELSE NULL END WHERE id=a.id;
 RETURN jsonb_build_object('error','Incorrect username or password.');END IF;
 UPDATE exq_accounts SET failed_attempts=0,locked_until=NULL WHERE id=a.id;
 token=encode(gen_random_bytes(32),'hex');INSERT INTO exq_sessions(token_hash,account_id) VALUES(encode(digest(token,'sha256'),'hex'),a.id);
 RETURN jsonb_build_object('token',token,'expires_at',extract(epoch FROM(now()+interval '7 days')),'user',jsonb_build_object('id',a.id,'user_metadata',jsonb_build_object('display_name',a.display_name),'username',a.username));
END;$$;
CREATE OR REPLACE FUNCTION public.exq_logout(p_token text) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
 UPDATE exq_sessions SET expires_at=now() WHERE token_hash=encode(digest(p_token,'sha256'),'hex');
$$;
REVOKE ALL ON FUNCTION public.exq_register(text,text,text),public.exq_login(text,text),public.exq_logout(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exq_register(text,text,text),public.exq_login(text,text),public.exq_logout(text) TO anon,authenticated;
COMMIT;

BEGIN;
DO $guard$ BEGIN IF to_regprocedure('public.exq_start(text,text)') IS NOT NULL THEN EXECUTE 'REVOKE ALL ON FUNCTION public.exq_start(text,text),public.exq_question(uuid),public.exq_answer(uuid,integer,text) FROM anon,authenticated';END IF;END $guard$;
CREATE TABLE IF NOT EXISTS public.exq_countries (code text PRIMARY KEY, name text NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS public.exq_rounds (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, player_name text NOT NULL CHECK (length(player_name) BETWEEN 2 AND 20),
 difficulty text NOT NULL, duration integer NOT NULL, questions jsonb NOT NULL, question_index integer NOT NULL DEFAULT 1,
 question_started_at timestamptz, score integer NOT NULL DEFAULT 0, correct_count integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(), finished_at timestamptz, last_result jsonb
);
ALTER TABLE public.exq_countries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exq_rounds ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exq_countries,public.exq_rounds FROM anon,authenticated;
CREATE INDEX IF NOT EXISTS exq_scores_idx ON public.exq_rounds (score DESC,finished_at) WHERE finished_at IS NOT NULL;
CREATE OR REPLACE FUNCTION public.exq_start(p_name text,p_difficulty text DEFAULT 'adventurer',p_token text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE names text[]; qs jsonb='[]'::jsonb; c record; opts jsonb; rid uuid; seconds integer; uid uuid;
BEGIN
 p_name=trim(p_name);
 IF p_token IS NOT NULL THEN SELECT account_id INTO uid FROM exq_sessions WHERE token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND expires_at>now(); IF uid IS NULL THEN RAISE EXCEPTION 'Your login expired. Log in again.';END IF; END IF;
 IF p_name !~ '^[A-Za-z0-9 _.-]{2,20}$' THEN RAISE EXCEPTION 'Choose a player name with 2–20 letters, numbers or spaces.'; END IF;
 IF p_difficulty NOT IN ('explorer','adventurer','expert') THEN RAISE EXCEPTION 'Choose a valid pace.'; END IF;
 seconds=CASE p_difficulty WHEN 'explorer' THEN 30 WHEN 'expert' THEN 10 ELSE 20 END;
 FOR c IN SELECT code,name FROM exq_countries ORDER BY random() LIMIT 10 LOOP
 SELECT jsonb_agg(n ORDER BY random()) INTO opts FROM (SELECT c.name AS n UNION ALL SELECT name FROM (SELECT name FROM exq_countries WHERE code<>c.code ORDER BY random() LIMIT 3) t) x;
 qs=qs||jsonb_build_array(jsonb_build_object('flag',c.code,'answer',c.name,'options',opts));
 END LOOP;
 IF jsonb_array_length(qs)<>10 THEN RAISE EXCEPTION 'Country data is not ready. Please try again.'; END IF;
 INSERT INTO exq_rounds(user_id,player_name,difficulty,duration,questions) VALUES(uid,p_name,p_difficulty,seconds,qs) RETURNING id INTO rid;
 RETURN jsonb_build_object('game_id',rid,'player_name',p_name,'difficulty',p_difficulty);
END;$$;
CREATE OR REPLACE FUNCTION public.exq_question(p_game uuid,p_token text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE g exq_rounds%ROWTYPE; q jsonb; remaining numeric;
BEGIN
 SELECT * INTO g FROM exq_rounds WHERE id=p_game FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Round not found. Start a new game.'; END IF;
 IF g.user_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM exq_sessions WHERE account_id=g.user_id AND token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND expires_at>now()) THEN RAISE EXCEPTION 'Please log in to resume this round.'; END IF;
 IF g.finished_at IS NOT NULL THEN RETURN g.last_result; END IF;
 IF g.created_at<now()-interval '1 hour' THEN RAISE EXCEPTION 'This round expired. Start a new game.'; END IF;
 IF g.question_started_at IS NULL THEN UPDATE exq_rounds SET question_started_at=clock_timestamp() WHERE id=p_game RETURNING * INTO g; END IF;
 q=g.questions->(g.question_index-1);
 remaining=greatest(0,g.duration-extract(epoch FROM(clock_timestamp()-g.question_started_at)));
 RETURN jsonb_build_object('index',g.question_index,'flag',q->>'flag','options',q->'options','score',g.score,'duration',g.duration,'remaining',remaining,'finished',false);
END;$$;
CREATE OR REPLACE FUNCTION public.exq_answer(p_game uuid,p_index integer,p_choice text DEFAULT NULL,p_token text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE g exq_rounds%ROWTYPE; q jsonb; elapsed numeric; hit boolean; bonus integer; points integer; result jsonb;
BEGIN
 SELECT * INTO g FROM exq_rounds WHERE id=p_game FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Round not found. Start a new game.'; END IF;
 IF g.user_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM exq_sessions WHERE account_id=g.user_id AND token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND expires_at>now()) THEN RAISE EXCEPTION 'Please log in to resume this round.'; END IF;
 IF p_index=g.question_index-1 AND g.last_result IS NOT NULL THEN RETURN g.last_result; END IF;
 IF g.finished_at IS NOT NULL OR p_index<>g.question_index OR g.question_started_at IS NULL THEN RAISE EXCEPTION 'Refresh the question before answering.'; END IF;
 IF g.created_at<now()-interval '1 hour' THEN RAISE EXCEPTION 'This round expired. Start a new game.'; END IF;
 q=g.questions->(g.question_index-1); elapsed=extract(epoch FROM(clock_timestamp()-g.question_started_at));
 hit=coalesce(p_choice=q->>'answer',false) AND elapsed<=g.duration+0.5;
 bonus=CASE WHEN hit THEN greatest(0,least(100,floor(100*(g.duration-elapsed)/g.duration)::integer)) ELSE 0 END;
 points=CASE WHEN hit THEN 100+bonus ELSE 0 END;
 result=jsonb_build_object('correct',hit,'answer',q->>'answer','points',points,'bonus',bonus,'score',g.score+points,'correct_count',g.correct_count+CASE WHEN hit THEN 1 ELSE 0 END,'finished',g.question_index=10);
 UPDATE exq_rounds SET score=g.score+points,correct_count=g.correct_count+CASE WHEN hit THEN 1 ELSE 0 END,question_index=g.question_index+1,question_started_at=NULL,last_result=result,finished_at=CASE WHEN g.question_index=10 THEN clock_timestamp() ELSE NULL END WHERE id=p_game;
 RETURN result;
END;$$;
CREATE OR REPLACE FUNCTION public.exq_leaderboard() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM (SELECT player_name,score,correct_count,difficulty,finished_at FROM exq_rounds WHERE finished_at IS NOT NULL ORDER BY score DESC,finished_at ASC LIMIT 20) t;
$$;
REVOKE ALL ON FUNCTION public.exq_start(text,text,text),public.exq_question(uuid,text),public.exq_answer(uuid,integer,text,text),public.exq_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exq_start(text,text,text),public.exq_question(uuid,text),public.exq_answer(uuid,integer,text,text),public.exq_leaderboard() TO anon,authenticated;
INSERT INTO public.exq_countries(code,name) VALUES ('gb','United Kingdom'),('ie','Ireland'),('fr','France'),('de','Germany'),('es','Spain'),('pt','Portugal'),('it','Italy'),('nl','Netherlands'),('be','Belgium'),('ch','Switzerland'),('at','Austria'),('dk','Denmark'),('se','Sweden'),('no','Norway'),('fi','Finland'),('pl','Poland'),('cz','Czechia'),('gr','Greece'),('tr','Turkey'),('ua','Ukraine'),('is','Iceland'),('us','United States'),('ca','Canada'),('mx','Mexico'),('br','Brazil'),('ar','Argentina'),('cl','Chile'),('pe','Peru'),('co','Colombia'),('uy','Uruguay'),('cr','Costa Rica'),('cu','Cuba'),('jm','Jamaica'),('au','Australia'),('nz','New Zealand'),('jp','Japan'),('kr','South Korea'),('cn','China'),('in','India'),('pk','Pakistan'),('bd','Bangladesh'),('lk','Sri Lanka'),('np','Nepal'),('th','Thailand'),('vn','Vietnam'),('id','Indonesia'),('my','Malaysia'),('sg','Singapore'),('ph','Philippines'),('kh','Cambodia'),('la','Laos'),('mn','Mongolia'),('kz','Kazakhstan'),('uz','Uzbekistan'),('ae','United Arab Emirates'),('sa','Saudi Arabia'),('il','Israel'),('jo','Jordan'),('eg','Egypt'),('ma','Morocco'),('tn','Tunisia'),('za','South Africa'),('ke','Kenya'),('ng','Nigeria'),('gh','Ghana'),('et','Ethiopia'),('tz','Tanzania'),('ug','Uganda'),('bw','Botswana'),('na','Namibia'),('mg','Madagascar'),('mu','Mauritius'),('sc','Seychelles'),('zw','Zimbabwe'),('rw','Rwanda'),('cm','Cameroon'),('sn','Senegal'),('ci','Côte d''Ivoire (Ivory Coast)') ON CONFLICT(code) DO UPDATE SET name=excluded.name;
COMMIT;
