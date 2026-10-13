-- Funções auxiliares dos testes locais (não vão para o Supabase)
create schema teste;
grant usage on schema teste to authenticated, anon, service_role;

create function teste.ok(nome text) returns void language plpgsql as $$
begin raise notice 'OK: %', nome; end $$;

create function teste.igual(obtido anyelement, esperado anyelement, nome text) returns void language plpgsql as $$
begin
  if obtido is distinct from esperado then
    raise exception 'FALHOU: % — esperado %, obtido %', nome, esperado, obtido;
  end if;
  raise notice 'OK: %', nome;
end $$;

-- Executa um comando e exige que falhe com o SQLSTATE indicado
create function teste.erro(comando text, sqlstate_esperado text, nome text) returns void language plpgsql as $$
begin
  begin
    execute comando;
  exception when others then
    if sqlstate = sqlstate_esperado then
      raise notice 'OK: %', nome;
      return;
    end if;
    raise exception 'FALHOU: % — esperado erro %, obtido % (%)', nome, sqlstate_esperado, sqlstate, sqlerrm;
  end;
  raise exception 'FALHOU: % — o comando deveria ter falhado (%)', nome, sqlstate_esperado;
end $$;

-- Executa um comando e retorna quantas linhas ele afetou
create function teste.linhas(comando text) returns bigint language plpgsql as $$
declare n bigint;
begin execute comando; get diagnostics n = row_count; return n; end $$;

-- Troca a sessão para um usuário autenticado (chamar como postgres)
create function teste.como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
end $$;

create function teste.novo_usuario(p_email text, p_nome text default null) returns uuid language sql as $$
  insert into auth.users (email, raw_user_meta_data)
  values (p_email, case when p_nome is null then '{}'::jsonb else jsonb_build_object('nome', p_nome) end)
  returning id;
$$;

create table teste.ids (k text primary key, v uuid);
grant select, insert, update on teste.ids to authenticated, service_role;
create function teste.id(k text) returns uuid language sql stable as $$ select v from teste.ids where ids.k = id.k $$;

grant execute on all functions in schema teste to authenticated, anon, service_role;

-- ---------------------------------------------------------------------
-- Transações simultâneas: conexões paralelas reais via dblink
-- ---------------------------------------------------------------------
create extension if not exists dblink schema teste;

-- Abre uma conexão paralela já identificada como um usuário (ou servidor)
create function teste.c_abrir(con text, p_uid uuid) returns void language plpgsql as $$
begin
  perform teste.dblink_connect(con, format('host=%s port=%s user=postgres dbname=%s',
    coalesce(nullif(current_setting('unix_socket_directories'), ''), '/tmp'), current_setting('port'), current_database()));
  if p_uid is null then
    perform teste.dblink_exec(con, $c$ set role service_role $c$);
    perform teste.dblink_exec(con, $c$ set "request.jwt.claims" = '{"role":"service_role"}' $c$);
  else
    perform teste.dblink_exec(con, 'set role authenticated');
    perform teste.dblink_exec(con, format($c$ set "request.jwt.claim.sub" = %L $c$, p_uid));
    perform teste.dblink_exec(con, format($c$ set "request.jwt.claims" = %L $c$,
                                    json_build_object('sub', p_uid, 'role', 'authenticated')));
  end if;
end $$;

create function teste.c_fechar(con text) returns void language sql as $$ select teste.dblink_disconnect(con) $$;

-- Executa um comando na conexão e espera terminar (devolve texto ou ERRO:<sqlstate>)
create function teste.c_executar(con text, comando text) returns text language plpgsql as $$
begin
  perform teste.dblink_send_query(con, comando);
  return teste.c_resultado(con);
end $$;

-- Dispara um comando sem esperar
create function teste.c_disparar(con text, comando text) returns void language plpgsql as $$
begin perform teste.dblink_send_query(con, comando); end $$;

-- A conexão continua ocupada (bloqueada por outra transação)?
create function teste.c_bloqueada(con text) returns boolean language plpgsql as $$
begin
  perform pg_sleep(0.4);
  return teste.dblink_is_busy(con) = 1;
end $$;

-- Aguarda o resultado do comando disparado: valor (texto) ou ERRO:<sqlstate>
create function teste.c_resultado(con text) returns text language plpgsql as $$
declare v text;
begin
  begin
    select t.r into v from teste.dblink_get_result(con) as t(r text);
  exception when others then
    perform * from teste.dblink_get_result(con, false) as t(r text);
    return 'ERRO:' || sqlstate;
  end;
  perform * from teste.dblink_get_result(con, false) as t(r text);
  return v;
end $$;
