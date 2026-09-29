# Orion PLuS: como colocar no ar 🎈

O **Orion PLuS** é o site de aniversariantes da Orion. O nome vem de **P**atrícia, **L**uís e **S**arah. É uma página só (`index.html`) e usa o **mesmo Supabase e o mesmo login do GPS Orion**.

Para ver o visual sem login, abra o site com `?demo=1` no fim do endereço. Os dados são de exemplo e nada é salvo.

---

## Passo 1: criar as tabelas no Supabase (uma vez só)

1. Entre no Supabase, no projeto do GPS Orion.
2. Abra **SQL Editor → New query**.
3. Cole o arquivo **`supabase/01_estrutura.sql`** inteiro e clique em **Run**.

Esse arquivo:
- cria as tabelas `plus_aniversariantes`, `plus_config` e `plus_envios`;
- cria o armazenamento de fotos `plus-fotos`;
- agenda a rotina diária das **8h**.

Ele não mexe em nada do GPS e pode ser rodado de novo sem problema.

> Se der erro em `pg_cron` ou `pg_net`: vá em **Database → Extensions**, ligue as duas e rode de novo.

Depois rode também o **`supabase/02_cor_e_aviso_imediato.sql`**, do mesmo jeito. Ele acrescenta:
- a **cor da bolinha** que cada pessoa escolhe;
- o **aviso imediato**: se alguém se cadastra a poucos dias do aniversário, o e-mail "está chegando" sai na hora. Se o cadastro for no próprio dia, o parabéns vai pro Teams na hora.

E rode o **`supabase/03_aviso_para_quem_chegou_depois.sql`**. Com ele, quem entra no PLuS depois que um aviso já saiu recebe esse aviso só pra ela, desde que o aniversário ainda não tenha chegado. Quem já estava na lista quando o aviso saiu não recebe de novo.

E rode o **`supabase/04_cartao_individual.sql`**. Com ele, o post do Teams no dia mostra o **cartão "Feliz Aniversário"** da pessoa no lugar da foto simples.
- O site desenha e guarda o cartão sempre que alguém salva o cadastro.
- Quem já estava cadastrado ganha o cartão sozinho no próximo acesso.
- Também dá pra gerar os que faltarem em **Administração → Pessoas → 🖼️ Gerar cartões que faltam**.

### E-mail de confirmação com código

O PLuS confirma o e-mail da conta nova com um **código de 6 números**, digitado na própria tela. Assim não depende do link, que dá erro porque o site é aberto como arquivo. Para o código aparecer no e-mail:

1. No Supabase, vá em **Authentication → Emails → Confirm signup**.
2. Troque o **Body** pelo texto abaixo e salve. O link continua lá, pra quem cria conta pelo GPS.

```html
<h2>Confirme seu e-mail 🎈</h2>
<p>Seu código de confirmação é:</p>
<p style="font-size:30px;font-weight:bold;letter-spacing:6px;">{{ .Token }}</p>
<p>Digite esse código na tela do <b>Orion PLuS</b>.</p>
<p style="font-size:12px;color:#888;">Criando conta pelo GPS Orion? Use este link: <a href="{{ .ConfirmationURL }}">confirmar e-mail</a>.</p>
```

## Passo 2: publicar o site

A sugestão é criar um repositório novo no **mesmo GitHub do GPS** (`sarahoriontr`), por exemplo `orion-plus`. Depois é só subir o `index.html` e ligar o GitHub Pages.

Assim o site fica em `https://sarahoriontr.github.io/orion-plus/`. Como fica no mesmo endereço-base do GPS, **quem já está logado no GPS entra direto no PLuS**.

Depois, no Supabase, vá em **Authentication → URL Configuration → Redirect URLs** e adicione o endereço do PLuS.

## Passo 3: grupo do Teams (parabéns no dia)

1. Crie uma equipe no Teams, por exemplo **"Orion Aniversários 🎂"**, e adicione todo mundo.
   - Também pode ser um canal dentro de uma equipe que já tenha a empresa toda.
2. No canal, clique em **⋯ → Fluxos de trabalho (Workflows)**.
3. Escolha **"Postar em um canal quando uma solicitação de webhook for recebida"**.
4. Dê o nome "Orion PLuS", escolha a equipe e o canal e clique em **Adicionar**.
5. **Copie o link** que aparece no final.

> 💡 Crie o fluxo logado **na conta do RH**. O post aparece como "*nome da conta* via Workflows".

## Passo 4: fluxo de e-mail (aviso antes do aniversário)

Crie o fluxo em [make.powerautomate.com](https://make.powerautomate.com), de preferência também logado na conta do RH, porque o e-mail sai dessa caixa.

1. Clique em **Criar → Fluxo da nuvem instantâneo**.
2. Escolha o gatilho **"Quando uma solicitação de webhook do Teams for recebida"** (*When a Teams webhook request is received*).
   - Em "Quem pode disparar o fluxo", marque **Qualquer pessoa**.
3. Adicione a ação **"Analisar JSON"** (*Parse JSON*):
   - **Conteúdo**: o *Corpo* do gatilho.
   - **Esquema**: cole o texto abaixo.
   ```json
   {
     "type": "object",
     "properties": {
       "destinatarios": { "type": "string" },
       "assunto": { "type": "string" },
       "mensagem_html": { "type": "string" }
     }
   }
   ```
4. Adicione a ação **Office 365 Outlook → "Enviar um email (V2)"**:
   - **Para**: o e-mail do próprio RH.
   - **Cco** (*Mostrar opções avançadas*): `destinatarios`. Com Cco, ninguém vê a lista inteira.
   - **Assunto**: `assunto`.
   - **Corpo**: clique no botão **`</>`** (modo código) e coloque `mensagem_html`.
5. **Salve** o fluxo. Depois abra o gatilho de novo e **copie o link** (HTTP URL).

O aviso vai para **todos menos o aniversariante**. Ele é enviado para:
- quem tem cadastro no PLuS;
- quem tem conta no GPS;
- os "e-mails extras" da configuração.

Um detalhe: **não coloque nos extras uma lista de distribuição que inclua todo mundo**, senão o aniversariante também recebe e a surpresa vaza.

## Passo 5: ligar tudo no site

1. Entre no PLuS com uma conta de **administrador**.
2. Vá em **Administração → 🤖 Avisos automáticos** e:
   - cole o link do Teams (passo 3) e o link do e-mail (passo 4);
   - confira os dias de antecedência (padrão: 3; se cair no fim de semana, o aviso vai na sexta);
   - confira o endereço do site.
3. Clique em **Salvar** e depois em **🧪 Testar Teams** e **🧪 Testar e-mail** (o teste de e-mail vai só pra você).

Se o teste do Teams falhar por causa da menção (@), desmarque "Marcar o aniversariante" e teste de novo.

## Passo 6: importar as fotos antigas

Em **Administração → 📥 Importar fotos antigas**, selecione todas as fotos de uma vez.
- O site lê nome e data do nome do arquivo (`Aline 11.05.jpg`, `Patricia - 21.04.png`...).
- Confira a tabela e clique em **Importar**.
- Quando essa pessoa criar a conta, o site pergunta **"é você?"** e junta os cadastros, sem duplicar.

---

## Quem é administrador

Quem já é **administrador no GPS** (Patrícia, Sarah, Guilherme) já é administrador no PLuS.

Para dar acesso de administrador **só no PLuS** a alguém (ex.: Luís), rode no SQL Editor **um** dos comandos abaixo, trocando o e-mail. Se não souber qual serve, tente o primeiro; se der erro, use o segundo.

```sql
-- se a coluna abas for text[] (tente este primeiro):
update usuarios_permissoes set abas = array_append(abas, 'plus_admin') where email = 'luis@oriontransmissao.com.br';
-- se der erro, a coluna é jsonb:
update usuarios_permissoes set abas = abas || '["plus_admin"]'::jsonb where email = 'luis@oriontransmissao.com.br';
```

## Como funciona, em resumo

- **Login**: mesma conta do GPS. No PLuS não precisa de aprovação: qualquer e-mail `@oriontransmissao.com.br` entra.
- **Cadastro**: foto, dia e mês são obrigatórios, junto com a autorização de uso da imagem (LGPD). O ano **não** é pedido.
- **Todo dia às 8h** o Supabase roda `plus_rodar_avisos()`:
  - 🎂 **no dia**: post no Teams com a foto;
  - 📧 **N dias antes**: e-mail para todos menos o aniversariante.

  Nada é mandado duas vezes: tudo fica registrado em `plus_envios`.
- **29/02**: em ano que não é bissexto, o aniversário é comemorado em 28/02.
- **Cartaz do mês**: o botão 🖼️ gera um PNG no tamanho A4, no estilo do cartaz antigo.
- **Fotos**: ficam no bucket público `plus-fotos`, porque o Teams e o e-mail precisam abrir a foto sem login. Os nomes dos arquivos são aleatórios.
