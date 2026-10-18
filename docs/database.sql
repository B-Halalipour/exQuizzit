BEGIN;
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
CREATE OR REPLACE FUNCTION public.exq_start(p_name text,p_difficulty text DEFAULT 'adventurer') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE names text[]; qs jsonb='[]'::jsonb; c record; opts jsonb; rid uuid; seconds integer;
BEGIN
 p_name=trim(p_name);
 IF p_name !~ '^[A-Za-z0-9 _.-]{2,20}$' THEN RAISE EXCEPTION 'Choose a player name with 2–20 letters, numbers or spaces.'; END IF;
 IF p_difficulty NOT IN ('explorer','adventurer','expert') THEN RAISE EXCEPTION 'Choose a valid pace.'; END IF;
 seconds=CASE p_difficulty WHEN 'explorer' THEN 30 WHEN 'expert' THEN 10 ELSE 20 END;
 FOR c IN SELECT code,name FROM exq_countries ORDER BY random() LIMIT 10 LOOP
 SELECT jsonb_agg(n ORDER BY random()) INTO opts FROM (SELECT c.name AS n UNION ALL SELECT name FROM (SELECT name FROM exq_countries WHERE code<>c.code ORDER BY random() LIMIT 3) t) x;
 qs=qs||jsonb_build_array(jsonb_build_object('flag',c.code,'answer',c.name,'options',opts));
 END LOOP;
 IF jsonb_array_length(qs)<>10 THEN RAISE EXCEPTION 'Country data is not ready. Please try again.'; END IF;
 INSERT INTO exq_rounds(user_id,player_name,difficulty,duration,questions) VALUES(auth.uid(),p_name,p_difficulty,seconds,qs) RETURNING id INTO rid;
 RETURN jsonb_build_object('game_id',rid,'player_name',p_name,'difficulty',p_difficulty);
END;$$;
CREATE OR REPLACE FUNCTION public.exq_question(p_game uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE g exq_rounds%ROWTYPE; q jsonb; remaining numeric;
BEGIN
 SELECT * INTO g FROM exq_rounds WHERE id=p_game FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Round not found. Start a new game.'; END IF;
 IF g.user_id IS NOT NULL AND g.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Please log in to resume this round.'; END IF;
 IF g.finished_at IS NOT NULL THEN RETURN g.last_result; END IF;
 IF g.created_at<now()-interval '1 hour' THEN RAISE EXCEPTION 'This round expired. Start a new game.'; END IF;
 IF g.question_started_at IS NULL THEN UPDATE exq_rounds SET question_started_at=clock_timestamp() WHERE id=p_game RETURNING * INTO g; END IF;
 q=g.questions->(g.question_index-1);
 remaining=greatest(0,g.duration-extract(epoch FROM(clock_timestamp()-g.question_started_at)));
 RETURN jsonb_build_object('index',g.question_index,'flag',q->>'flag','options',q->'options','score',g.score,'duration',g.duration,'remaining',remaining,'finished',false);
END;$$;
CREATE OR REPLACE FUNCTION public.exq_answer(p_game uuid,p_index integer,p_choice text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE g exq_rounds%ROWTYPE; q jsonb; elapsed numeric; hit boolean; bonus integer; points integer; result jsonb;
BEGIN
 SELECT * INTO g FROM exq_rounds WHERE id=p_game FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Round not found. Start a new game.'; END IF;
 IF g.user_id IS NOT NULL AND g.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Please log in to resume this round.'; END IF;
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
REVOKE ALL ON FUNCTION public.exq_start(text,text),public.exq_question(uuid),public.exq_answer(uuid,integer,text),public.exq_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.exq_start(text,text),public.exq_question(uuid),public.exq_answer(uuid,integer,text),public.exq_leaderboard() TO anon,authenticated;
INSERT INTO public.exq_countries(code,name) VALUES ('gb','United Kingdom'),('ie','Ireland'),('fr','France'),('de','Germany'),('es','Spain'),('pt','Portugal'),('it','Italy'),('nl','Netherlands'),('be','Belgium'),('ch','Switzerland'),('at','Austria'),('dk','Denmark'),('se','Sweden'),('no','Norway'),('fi','Finland'),('pl','Poland'),('cz','Czechia'),('gr','Greece'),('tr','Turkey'),('ua','Ukraine'),('is','Iceland'),('us','United States'),('ca','Canada'),('mx','Mexico'),('br','Brazil'),('ar','Argentina'),('cl','Chile'),('pe','Peru'),('co','Colombia'),('uy','Uruguay'),('cr','Costa Rica'),('cu','Cuba'),('jm','Jamaica'),('au','Australia'),('nz','New Zealand'),('jp','Japan'),('kr','South Korea'),('cn','China'),('in','India'),('pk','Pakistan'),('bd','Bangladesh'),('lk','Sri Lanka'),('np','Nepal'),('th','Thailand'),('vn','Vietnam'),('id','Indonesia'),('my','Malaysia'),('sg','Singapore'),('ph','Philippines'),('kh','Cambodia'),('la','Laos'),('mn','Mongolia'),('kz','Kazakhstan'),('uz','Uzbekistan'),('ae','United Arab Emirates'),('sa','Saudi Arabia'),('il','Israel'),('jo','Jordan'),('eg','Egypt'),('ma','Morocco'),('tn','Tunisia'),('za','South Africa'),('ke','Kenya'),('ng','Nigeria'),('gh','Ghana'),('et','Ethiopia'),('tz','Tanzania'),('ug','Uganda'),('bw','Botswana'),('na','Namibia'),('mg','Madagascar'),('mu','Mauritius'),('sc','Seychelles'),('zw','Zimbabwe'),('rw','Rwanda'),('cm','Cameroon'),('sn','Senegal'),('ci','Côte d''Ivoire (Ivory Coast)') ON CONFLICT(code) DO UPDATE SET name=excluded.name;
COMMIT;
