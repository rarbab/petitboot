
%pure-parser
%lex-param { yyscan_t scanner }
%parse-param { struct grub2_parser *parser }
%error-verbose

%{
#include <talloc/talloc.h>

#include "grub2.h"
#include "parser.h"
#include "lexer.h"

static void print_token(FILE *fp, int type, YYSTYPE value);

#define YYLEX_PARAM parser->scanner
#define YYPRINT(f, t, v) print_token(f, t, v)

static void yyerror(struct grub2_parser *, char const *s);
%}

%union {
	struct grub2_word	*word;
	struct grub2_argv	*argv;
	struct grub2_statement	*statement;
	struct grub2_statements	*statements;
}

/* reserved words */
%token	TOKEN_LDSQBRACKET	"[["
%token	TOKEN_RDSQBRACKET	"]]"
%token	TOKEN_CASE		"case"
%token	TOKEN_DO		"do"
%token	TOKEN_DONE		"done"
%token	TOKEN_ELIF		"elif"
%token	TOKEN_ELSE		"else"
%token	TOKEN_ESAC		"esac"
%token	TOKEN_FI		"fi"
%token	TOKEN_FOR		"for"
%token	TOKEN_FUNCTION		"function"
%token	TOKEN_IF		"if"
%token	TOKEN_IN		"in"
%token	TOKEN_MENUENTRY		"menuentry"
%token	TOKEN_SELECT		"select"
%token	TOKEN_SUBMENU		"submenu"
%token	TOKEN_THEN		"then"
%token	TOKEN_TIME		"time"
%token	TOKEN_UTIL		"until"
%token	TOKEN_WHILE		"while"

%type <statement>	statement
%type <statements>	statements
%type <statement>	conditional
%type <statement>	elif
%type <statements>	elifs
%type <argv>		words
%type <word>		word

/* syntax */
%token	TOKEN_EOL
%token	TOKEN_DELIM
%token	<word> TOKEN_WORD
%token	TOKEN_EOF 0

%start	script
%debug

%%

script:	statements {
		parser->script->statements = $1;
	}

eol:	TOKEN_EOL | TOKEN_EOF;

statements: /* empty */ {
		$$ = create_statements(parser);
	}
	| statements statement eol {
		statement_append($1, $2);
		$$ = $1;
	}
	| statements TOKEN_EOL {
		$$ = $1;
	}

conditional: statement TOKEN_EOL "then" TOKEN_EOL statements {
		$$ = create_statement_conditional(parser, $1, $5);
	}

elif: "elif" TOKEN_DELIM conditional {
		$$ = $3;
      }

elifs: /* empty */ {
		$$ = create_statements(parser);
	}
	| elifs elif {
		statement_append($1, $2);
		$$ = $1;
	}

statement:
	words {
		   $$ = create_statement_simple(parser, $1);
	}
	| '{' statements '}' {
		$$ = create_statement_block(parser, $2);
	}
	| "if" TOKEN_DELIM conditional elifs "fi" {
		$$ = create_statement_if(parser, $3, $4, NULL);
	}
	| "if" TOKEN_DELIM conditional
		elifs
		"else" TOKEN_EOL
		statements
		"fi" {
		$$ = create_statement_if(parser, $3, $4, $7);
	}
	| "function" TOKEN_DELIM word TOKEN_DELIM '{' statements '}' {
		$$ = create_statement_function(parser, $3, $6);
	}
	| "menuentry" TOKEN_DELIM words TOKEN_DELIM
		'{' statements '}' {
		$$ = create_statement_menuentry(parser, $3, $6);
	}
	| "submenu" TOKEN_DELIM words TOKEN_DELIM
		'{' statements '}' {
		/* we just flatten everything */
		$$ = create_statement_block(parser, $6);
	}

words:	word {
		$$ = create_argv(parser);
		argv_append($$, $1);
	}
	| words TOKEN_DELIM word {
		argv_append($1, $3);
		$$ = $1;
	}

word:	TOKEN_WORD
	| word TOKEN_WORD {
		word_append($1, $2);
		$$ = $1;
	}

%%
void yyerror(struct grub2_parser *parser, char const *s)
{
	fprintf(stderr, "%d: error: %s '%s'\n",
			yyget_lineno(parser->scanner),
			s, yyget_text(parser->scanner));
}

static void print_token(FILE *fp, int type, YYSTYPE value)
{
	if (type != TOKEN_WORD)
		return;
	fprintf(fp, "%s", value.word->text);
}

struct grub2_statements *create_statements(struct grub2_parser *parser)
{
	struct grub2_statements *stmts = talloc(parser,
			struct grub2_statements);
	list_init(&stmts->list);
	return stmts;
}

struct grub2_statement *create_statement_simple(struct grub2_parser *parser,
		struct grub2_argv *argv)
{
	struct grub2_statement_simple *stmt =
		talloc(parser, struct grub2_statement_simple);
	stmt->st.type = STMT_TYPE_SIMPLE;
	stmt->st.exec = statement_simple_execute;
	stmt->argv = argv;
	return &stmt->st;
}

struct grub2_statement *create_statement_menuentry(struct grub2_parser *parser,
		struct grub2_argv *argv, struct grub2_statements *stmts)
{
	struct grub2_statement_menuentry *stmt =
		talloc(parser, struct grub2_statement_menuentry);
	stmt->st.type = STMT_TYPE_MENUENTRY;
	stmt->st.exec = statement_menuentry_execute;
	stmt->argv = argv;
	stmt->statements = stmts;
	return &stmt->st;
}

struct grub2_statement *create_statement_conditional(
		struct grub2_parser *parser,
		struct grub2_statement *condition,
		struct grub2_statements *statements)
{
	struct grub2_statement_conditional *stmt =
		talloc(parser, struct grub2_statement_conditional);
	stmt->st.type = STMT_TYPE_CONDITIONAL;
	stmt->condition = condition;
	stmt->statements = statements;
	return &stmt->st;
}

struct grub2_statement *create_statement_if(struct grub2_parser *parser,
		struct grub2_statement *conditional,
		struct grub2_statements *elifs,
		struct grub2_statements *else_case)
{
	struct grub2_statement_if *stmt =
		talloc(parser, struct grub2_statement_if);

	list_add(&elifs->list, &conditional->list);

	stmt->st.type = STMT_TYPE_IF;
	stmt->st.exec = statement_if_execute;
	stmt->conditionals = elifs;
	stmt->else_case = else_case;
	return &stmt->st;
}

struct grub2_statement *create_statement_block(struct grub2_parser *parser,
		struct grub2_statements *stmts)
{
	struct grub2_statement_block *stmt =
		talloc(parser, struct grub2_statement_block);
	stmt->st.type = STMT_TYPE_BLOCK;
	stmt->st.exec = NULL;
	stmt->statements = stmts;
	return &stmt->st;
}

struct grub2_statement *create_statement_function(struct grub2_parser *parser,
		struct grub2_word *name, struct grub2_statements *body)
{
	struct grub2_statement_function *stmt =
		talloc(parser, struct grub2_statement_function);
	stmt->st.exec = statement_function_execute;
	stmt->name = name;
	stmt->body = body;
	return &stmt->st;
}

void statement_append(struct grub2_statements *stmts,
		struct grub2_statement *stmt)
{
	if (!stmt)
		return;
	list_add_tail(&stmts->list, &stmt->list);
}

struct grub2_word *create_word_text(struct grub2_parser *parser,
		const char *text)
{
	struct grub2_word *word = talloc(parser, struct grub2_word);
	word->type = GRUB2_WORD_TEXT;
	word->split = false;
	word->text = talloc_strdup(word, text);
	word->next = NULL;
	word->last = word;
	return word;
}

struct grub2_word *create_word_var(struct grub2_parser *parser,
		const char *name, bool split)
{
	struct grub2_word *word = talloc(parser, struct grub2_word);
	word->type = GRUB2_WORD_VAR;
	word->name = talloc_strdup(word, name);
	word->split = split;
	word->next = NULL;
	word->last = word;
	return word;
}

struct grub2_argv *create_argv(struct grub2_parser *parser)
{
	struct grub2_argv *argv = talloc(parser, struct grub2_argv);
	list_init(&argv->words);
	return argv;
}

void argv_append(struct grub2_argv *argv, struct grub2_word *word)
{
	list_add_tail(&argv->words, &word->argv_list);
}

void word_append(struct grub2_word *w1, struct grub2_word *w2)
{
	w1->last->next = w2;
	w1->last = w2;
}

struct grub2_parser *grub2_parser_create(struct discover_context *ctx)
{
	struct grub2_parser *parser;

	parser = talloc(ctx, struct grub2_parser);
	yylex_init_extra(parser, &parser->scanner);
	parser->script = create_script(parser, ctx);

	return parser;
}

void grub2_parser_parse(struct grub2_parser *parser, char *buf, int len)
{
	YY_BUFFER_STATE bufstate;
	int rc;

	bufstate = yy_scan_bytes(buf, len - 1, parser->scanner);

	rc = yyparse(parser);

	yy_delete_buffer(bufstate, parser->scanner);

	if (!rc)
		script_execute(parser->script);
}
