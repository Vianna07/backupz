# backupz

Gerenciador de backup PostgreSQL via Docker Compose.

Lê um arquivo de configuração `backupz.zon`, analisa o `docker-compose.yml`, detecta conflitos de porta entre bancos primários e secundários, remapeia portas automaticamente e executa o pipeline de backup.

[Read in English](README.md)

## Requisitos

- [Zig](https://ziglang.org/) 0.16+
- Docker (para o comando `run`)

## Build

```sh
zig build
```

O binário estará em `zig-out/bin/backupz`.

## Uso

```
backupz [opções] <comando>
```

### Comandos

| Comando | Descrição |
|---------|-----------|
| `check` | Valida o `backupz.zon` e mostra o plano de execução |
| `run`   | Executa o backup (roda o `check` primeiro, depois docker compose) |
| `help`  | Mostra informações de uso |

### Opções

| Opção | Descrição |
|-------|-----------|
| `-d <arquivo>` | Sobrescreve o caminho do arquivo compose |

### Exemplos

```sh
backupz check
backupz run
backupz -d docker-compose.prod.yml check
```

## Configuração

Crie um arquivo `backupz.zon` na raiz do projeto:

```zon
.{
    .compose_file = "examples/compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup.sql" },
    },
}
```

| Campo | Descrição |
|-------|-----------|
| `compose_file` | Caminho para o arquivo Docker Compose |
| `port_range_start` | Início do range de portas para remapeamento |
| `port_range_end` | Fim do range de portas |
| `databases` | Lista de bancos primários (nome do serviço + script SQL) |
| `skip_scripts` | (opcional) Lista de serviços secundários que NÃO devem herdar scripts |

### Suporte a múltiplos primários

Você pode definir múltiplos bancos primários:

```zon
.{
    .compose_file = "compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup_hom.sql" },
        .{ .service = "db-staging", .script = "backup_staging.sql" },
    },
}
```

### Herança de scripts

Bancos secundários que conflitam com um primário herdam automaticamente o script de backup do primário. Para pular a execução do script em secundários específicos:

```zon
.{
    .compose_file = "compose.yml",
    .port_range_start = 6100,
    .port_range_end = 6200,
    .databases = .{
        .{ .service = "db-hom", .script = "backup.sql" },
    },
    .skip_scripts = .{ "db-analytics" },
}
```

## Estrutura do projeto

```
backupz/
  backupz.zon              # configuração em tempo de execução
  build.zig                # script de build
  examples/
    compose.yml            # exemplo de arquivo Docker Compose
    scripts/
      backup.sql           # exemplo de script SQL de backup
      backup_other.sql     # exemplo de script SQL de backup (segundo primário)
  scripts/                 # scripts de CI/CD e teste
  src/                     # código fonte
```

O diretório `examples/` contém um exemplo funcional. O arquivo compose monta `./scripts` nos containers dos bancos para que `psql -f /scripts/<script>.sql` funcione em tempo de execução.

## Como funciona

1. **check** lê o `backupz.zon` e o arquivo compose
2. Identifica quais serviços secundários conflitam com as portas dos primários
3. Valida se o range de portas é suficiente para o remapeamento
4. Gera um plano de execução mostrando as reatribuições de porta

O comando **run** adicionalmente:

5. Valida que os arquivos de script existem no disco
6. Verifica se o Docker está disponível
7. Remove containers existentes para evitar conflitos de nome
8. Sobe todos os serviços com portas remapeadas e volume de scripts (via arquivo override gerado)
9. Aguarda o PostgreSQL ficar pronto e executa os scripts SQL em cada banco
10. Para os serviços secundários com conflito (primários e não-conflitantes continuam rodando)

## Testes

```sh
zig build test
```
