#!/usr/bin/env ruby
# coding: utf-8
require 'parslet'

class ECMAScriptParser < Parslet::Parser
  rule(:space) {
    white_space | line_terminator | comment
  }
  rule(:spaces?) {
    space.repeat
  }
  rule(:spaces) {
    space.repeat(1)
  }

  # 6 --
  rule(:source_character) {
    any
  }
  # -- 6

  # 7 --
  rule(:input_element_div) {
    white_space |
      line_terminator |
      comment |
      token |
      div_punctuator
  }
  # -- 7

  # 7.2 --
  rule(:white_space) {
    chars = [0x9, 0xb, 0xc, 0x20, 0xa0, 0xffff].map{ |n| n.chr('UTF-8') }
    match('['+chars.join+']|\p{Space_Separator}')
  }
  # -- 7.2

  # 7.3 --
  rule(:line_terminator) {
    chars = [0xa, 0xd, 0x2028, 0x2029].map{ |n| n.chr('UTF-8') }
    match('"'+chars.join+'"')
  }
  rule(:line_terminator_sequence) {
    str(0x9.chr('UTF-8')) |
      str(0xd.chr('UTF-8')) >> str(0xa.chr('UTF-8')).absent? |
      str(0x2028.chr('UTF-8')) |
      str(0x2029.chr('UTF-8')) |
      str(0xd.chr('UTF-8')) >> str(0xa.chr('UTF-8'))
  }
  # -- 7.3

  # 7.4 --
  rule(:comment) {
    multi_line_comment |
      single_line_comment
  }
  rule(:multi_line_comment) {
    str('/*') >> multi_line_comment_chars.maybe >> str('*/')
  }
  rule(:multi_line_comment_chars) {
    multi_line_not_asterisk_char >> multi_line_comment_chars.maybe |
      str('*') >> post_asterisk_comment_chars.maybe
  }
  rule(:post_asterisk_comment_chars) {
    multi_line_not_forward_slash_or_asterisk_char >> multi_line_comment_chars.maybe |
      str('*') >> post_asterisk_comment_chars.maybe
  }
  rule(:multi_line_not_asterisk_char) {
    str('*').absent? >> source_character
  }
  rule(:multi_line_not_forward_slash_or_asterisk_char) {
    match('[/*]').absent? >> source_character
  }
  rule(:single_line_comment) {
    str('//') >> single_line_comment_chars.maybe
  }
  rule(:single_line_comment_chars) {
    single_line_comment_char >> single_line_comment_chars.maybe
  }
  rule(:single_line_comment_char) {
    line_terminator.absent? >> source_character
  }
  # -- 7.4

  # 7.5 --
  rule(:token) {
    identifier_name |
      punctuator |
      numeric_literal |
      string_literal
  }
  # -- 7.5

  # 7.6 --
  rule(:identifier) {
    reserved_word.absent? >> identifier_name
  }
  rule(:identifier_name) {
    identifier_start >> identifier_part.repeat(1)
  }
  rule(:identifier_start) {
    unicode_letter | match('[$_]') | str('\\') >> unicode_escape_sequence
  }
  rule(:identifier_part) {
    identifier_start | unicode_combining_mark | unicode_digit | unicode_connector_punctuation | str(0x200c.chr('UTF-8')) | str(0x200d.chr('UTF-8'))
  }
  rule(:unicode_letter) {
    cats = [/\p{Uppercase_Letter}/, /\p{Lowercase_Letter}/,
            /\p{Titlecase_Letter}/, /\p{Modifier_Letter}/,
            /\p{Other_Letter}/, /\p{Letter_Number}/]
    match(cats.join('|'))
  }
  rule(:unicode_combining_mark) {
    cats = [/\p{Nonspacing_Mark}/, /\p{Combining_Mark}/]
    match(cats.join('|'))
  }
  rule(:unicode_digit) {
    match('\p{Decimal_Number}')
  }
  rule(:unicode_connector_punctuation) {
    match('\p{Connector_Punctuation}')
  }
  # -- 7.6

  # 7.6.1 --
  rule(:reserved_word) {
    keyword | future_reserved_word | null_literal | boolean_literal
  }
  # -- 7.6.1

  # 7.6.1.1 --
  rule(:keyword) {
    str('break') | str('do') | str('instanceof') | str('typeof') |
      str('case') | str('else') | str('new') | str('var') |
      str('catch') | str('finally') | str('return') | str('void') |
      str('continue') | str('for') | str('switch') | str('while') |
      str('debugger') | str('function') | str('this') | str('with') |
      str('default') | str('if') | str('throw') |
      str('delete') | str('in') | str('try')
  }
  # -- 7.6.1.1

  # 7.6.1.2 --
  rule(:future_reserved_word) {
    str('class') | str('enum') | str('extends') | str('super') |
      str('const') | str('export') | str('import') |
      # in strict mode
      str('implements') | str('let') | str('private') | str('public') | str('yield') |
      str('interrface') | str('package') | str('protected') | str('static')
  }
  # -- 7.6.1.2

  # 7.7 --
  rule(:punctuator) {
    match('[{}()\[\].;,<>+-*%&|^!~?:=]') | str('<=') |
      str('>=') | str('==') | str('!=') | str('===') | str('!==') |
      str('++') | str('--') |
      str('<<') | str('>>') | str('>>>') |
      str('&&') | str('||') |
      str('+=') | str('-=') | str('*=') | str('%=') | str('<<=') |
      str('>>=') | str('>>>=') | str('&=') | str('|=') | str('^=')
  }

  rule(:div_punctuator) {
    str('/') | str('/=')
  }
  # -- 7.7

  # 7.8 --
  rule(:literal) {
    null_literal | boolean_literal | numeric_literal | string_literal | regular_expression_literal
  }
  # -- 7.8

  # 7.8.1 --
  rule(:null_literal) {
    str('null')
  }
  # -- 7.8.1

  # 7.8.2 --
  rule(:boolean_literal) {
    str('true') | str('false')
  }
  # -- 7.8.2

  # 7.8.3 --
  rule(:numeric_literal) {
    decimal_literal | hex_integer_literal
  }
  rule(:decimal_literal) {
    decimal_integer_literal >> str('.') >> decimal_digits.maybe >> exponent_part.maybe |
      str('.') >> decimal_digits >> exponent_part.maybe |
      decimal_integer_literal >> exponent_part.maybe
  }
  rule(:decimal_integer_literal) {
    str('0') |
      non_zero_digit >> decimal_digits.maybe
  }
  rule(:decimal_digits) {
    decimal_digit.repeat(1)
  }
  rule(:decimal_digit) {
    match('[0-9]')
  }
  rule(:non_zero_digit) {
    match('[1-9]')
  }
  rule(:exponent_part) {
    exponent_indicator >> signed_integer
  }
  rule(:exponent_indicator) {
    str('e') | str('E')
  }
  rule(:signed_integer) {
    decimal_digits |
      str('+') >> decimal_digits |
      str('-') >> decimal_digits
  }
  rule(:hex_integer_literal) {
    str('0x') >> hex_digit.repeat(1) |
      str('0X') >> hex_digit.repeat(1)
  }
  rule(:hex_digit) {
    match('[0-9a-fA-F]')
  }
  # -- 7.8.3

  # 7.8.4 --
  rule(:string_literal) {
    str('"') >> double_string_characters.maybe >> str('"') |
      str("'") >> single_string_characters.maybe >> str("'")
  }
  rule(:double_string_characters) {
    double_string_character >> double_string_characters.maybe
  }
  rule(:single_string_characters) {
    single_string_character >> single_string_characters.maybe
  }
  rule(:double_string_character) {
    (match('["\]') | line_terminator).absent? >> source_character |
      str('\\') >> escape_sequence |
      line_continuation
  }
  rule(:single_string_character) {
    (match("['\]") | line_terminator).absent? >> source_character |
      str('\\') >> escape_sequence |
      line_continuation
  }
  rule(:line_continuation) {
    str('\\') >> line_terminator_sequence
  }
  rule(:escape_sequence) {
    charactor_escape_sequence |
      str('0') >> decimal_digit.absent? |
      hex_escape_sequence |
      unicode_escape_sequence
  }
  rule(:character_escape_sequence) {
    single_escape_character |
      non_escape_character
  }
  rule(:single_escape_character) {
    match('[\'"\\bfntrtv]')
  }
  rule(:non_escape_character) {
    (escape_character | line_terminator).absent? >> source_character
  }
  rule(:escape_character) {
    single_escape_character |
      decimal_digit |
      match('[xu]')
  }
  rule(:hex_escape_sequence) {
    str('x') >> hex_digit >> hex_digit
  }
  rule(:unicode_escape_sequence) {
    str('u') >> hex_digit >> hex_digit >> hex_digit >> hex_digit
  }
  # -- 7.8.4

  # 7.8.5 --
  rule(:regular_expression_literal) {
    str('/') >> regular_expression_body >> str('/') >> regular_expression_flags
  }
  rule(:regular_expression_body) {
    regular_expression_first_char >> regular_expression_chars
  }
  rule(:regular_expression_chars) {
    str('') |
      regular_expression_chars >> regular_expression_char
  }
  rule(:regular_expression_first_char) {
    match('[*\/[]').absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence |
      regular_expression_class
  }
  rule(:regular_expression_char) {
    match('[\/[]').absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence |
      regular_expression_class
  }
  rule(:regular_expression_backslash_sequence) {
    str('\\') >> regular_expression_non_terminator
  }
  rule(:regular_expression_non_terminator) {
    line_terminator.absent? >> source_character
  }
  rule(:regular_expression_class) {
    str('[') >> regular_expression_class_chars >> str(']')
  }
  rule(:regular_expression_class_chars) {
    # regular_expression_class_chars >> regular_expression_class_char
    str('') |
      regular_expression_class_char.repeat(1)
  }
  rule(:regular_expression_class_char) {
    match('[]\]').absent? >> regular_expression_non_terminator |
      regular_expression_backslash_sequence
  }
  rule(:regular_expression_flags) {
    # regular_expression_flags >> identifier_part
    str('') |
      identifier_part.repeat(1)
  }
  # -- 7.8.5

  # 11.1 --
  rule(:primary_expression) {
    str('this') |
      identifier |
      literal |
      array_literal |
      object_literal |
      str('(') >> spaces? >> expression >> spaces? >> str(')')
  }
  # -- 11.1

  # 11.1.4 --
  rule(:array_literal) {
    # str('[') >> elision.maybe >> str(']') |
    #   str('[') >> element_list >> str(']') |
    #   str('[') >> element_list >> str(',') >> elision.maybe >> str(']')
    str('[') >> (spaces? >> element.maybe >> spaces? >> str(',')).repeat >> spaces? >> str(']') |
      str('[') >> (spaces? >> element.maybe >> spaces? >> str(',')).repeat >> spaces? >> element >> spaces? >> str(']')
  }
  rule(:element) {
    assignment_expression
  }
  # rule(:element_list) {
  #   elision.maybe >> assignment_expression |
  #     element_list >> str(',') >> elision.maybe >> assignment_expression
  # }
  # rule(:elision) {
  #   str(',')
  # }
  # -- 11.1.4

  # 11.1.5 --
  rule(:object_literal) {
    str('{') >> (spaces? >> property_assignment >> spaces? >> str(',')).repeat >> spaces? >> str('}') |
      str('{') >> (spaces? >> property_assignment >> spaces? >> str(',')).repeat >> spaces? >> property_assignment >> spaces? >> str('}')
  }
  # rule(:property_name_and_value_list) {
  #   property_assignment |
  #     property_name_and_value_list >> str(',') >> property_assignment
  # }
  rule(:property_assignment) {
    property_name >> spaces? >> str(':') >> spaces? >> assignment_expression |
      str('get') >> spaces >> property_name >> spaces? >> str('(') >> spaces? >> str(')') >> spaces? >> str('{') >> spaces? >> function_body >> spaces? >> str('}') |
      str('set') >> spaces >> property_name >> spaces? >> str('(') >> spaces? >> property_set_parameter_list >> spaces? >> str(')') >> spaces? >> str('{') >> spaces? >> function_body >> spaces? >> str('}')
  }
  rule(:property_name) {
    identifier_name |
      string_literal |
      numeric_literal
  }
  rule(:property_set_parameter_list) {
    identifier
  }
  # -- 11.1.5

  # 11.2 -- Left-Hand-Side Expressions
  rule(:member_expression) {
    # primary_expression |
    #   function_expression |
    #   member_expression >> str('[') >> expression >> str(']') |
    #   member_expression >> str('.') >> identifier_name |
    #   str('new') >> member_expression >> arguments
    (primary_expression | function_expression | str('new') >> spaces >> member_expression >> spaces? >> arguments) >>
      (spaces? >> str('[') >> spaces? >> expression >> spaces? >> str(']') | spaces? >> str('.') >> spaces? >> identifier_name).repeat
  }
  rule(:new_expression) {
    member_expression |
      str('new') >> spaces >> new_expression
  }
  rule(:call_expression) {
    # member_expression >> arguments |
    #   call_expression >> arguments |
    #   call_expression >> str('[') >> expression >> str(']') |
    #   call_expression >> str('.') >> identifier_name
    (member_expression >> spaces? >> arguments) >> (spaces? >> arguments | spaces? >> str('[') >> spaces? >> expression >> spaces? >> str(']') | spaces? >> str('.') >> spaces? >> identifier_name).repeat
  }
  rule(:arguments) {
    str('(') >> spaces? >> str(')') |
      str('(') >> (spaces? >> assignment_expression >> spaces? >> str(',')).repeat >> spaces? >> assignment_expression >> spaces? >> str(')')
  }
  # rule(:argument_list) {
  #   assignment_expression |
  #     argument_list >> str(',') >> assignment_expression
  # }
  rule(:left_hand_side_expression) {
    new_expression |
      call_expression
  }
  # -- 11.2

  # 11.3 --
  rule(:postfix_expression) {
    left_hand_side_expression |
      left_hand_side_expression >> str('++') | # [no LineTerminator here] between lhse and ++
      left_hand_side_expression >> str('--')
  }
  # -- 11.3

  # 11.4 --
  rule(:unary_expression) {
    postfix_expression |
      str('delete') >> spaces? >> unary_expression |
      str('void') >> spaces? >> unary_expression |
      str('typeof') >> spaces? >> unary_expression |
      str('++') >> spaces? >> unary_expression |
      str('--') >> spaces? >> unary_expression |
      str('+') >> spaces? >> unary_expression |
      str('-') >> spaces? >> unary_expression |
      str('~') >> spaces? >> unary_expression |
      str('!') >> spaces? >> unary_expression
  }
  # -- 11.4

  # 11.5 --
  rule(:multiplicative_expression) {
    # unary_expression |
    #   multiplicative_expression >> str('*') >> unary_expression |
    #   multiplicative_expression >> str('/') >> unary_expression |
    #   multiplicative_expression >> str('%') >> unary_expression
    (unary_expression >> spaces? >> (str('*') | str('/') | str('%')) >> spaces?).repeat >> unary_expression
  }
  # -- 11.5

  # 11.6 --
  rule(:additive_expression) {
    # multiplicative_expression |
    #   additive_expression >> str('+') >> multiplicative_expression |
    #   additive_expression >> str('-') >> multiplicative_expression
    (multiplicative_expression >> spaces? >> (str('+') | str('-')) >> spaces?).repeat >> multiplicative_expression
  }
  # -- 11.6

  # 11.7 --
  rule(:shift_expression) {
    # additive_expression |
    #   shift_expression >> str('<<') >> additive_expression |
    #   shift_expression >> str('>>') >> additive_expression |
    #   shift_expression >> str('>>>') >> additive_expression
    (additive_expression >> spaces? >> (str('<<') | str('>>') | str('>>>')) >> spaces?).repeat >> additive_expression
  }
  # -- 11.7

  # 11.8 --
  rule(:relational_expression) {
    # shift_expression |
    #   relational_expression >> str('<') >> shift_expression |
    #   relational_expression >> str('>') >> shift_expression |
    #   relational_expression >> str('<=') >> shift_expression |
    #   relational_expression >> str('>=') >> shift_expression |
    #   relational_expression >> str('instanceof') >> shift_expression |
    #   relational_expression >> str('in') >> shift_expression
    (shift_expression >> spaces? >> (str('<') | str('>') | str('<=') | str('>=') | str('instanceof') | str('in')) >> spaces?).repeat >> shift_expression
  }
  rule(:relational_expression_no_in) {
    # shift_expression |
    #   relational_expression_no_in >> str('<') >> shift_expression |
    #   relational_expression_no_in >> str('>') >> shift_expression |
    #   relational_expression_no_in >> str('<=') >> shift_expression |
    #   relational_expression_no_in >> str('>=') >> shift_expression |
    #   relational_expression_no_in >> str('instanceof') >> shift_expression
    (shift_expression >> spaces? >> (str('<') | str('>') | str('<=') | str('>=') | str('instanceof')) >> spaces?).repeat >> shift_expression
  }
  # -- 11.8

  # 11.9 --
  rule(:equality_expression) {
    # relational_expression |
    #   equality_expression >> str('==') >> relational_expression |
    #   equality_expression >> str('!=') >> relational_expression |
    #   equality_expression >> str('===') >> relational_expression |
    #   equality_expression >> str('!==') >> relational_expression
    (relational_expression >> spaces? >> (str('==') | str('!=') | str('===') | str('!==')) >> spaces?).repeat >> relational_expression
  }
  rule(:equality_expression_no_in) {
    # relational_expression_no_in |
    #   equality_expression_no_in >> str('==') >> relational_expression_no_in |
    #   equality_expression_no_in >> str('!=') >> relational_expression_no_in |
    #   equality_expression_no_in >> str('===') >> relational_expression_no_in |
    #   equality_expression_no_in >> str('!==') >> relational_expression_no_in
    (relational_expression_no_in >> spaces? >> (str('==') | str('!=') | str('===') | str('!==')) >> spaces?).repeat >> relational_expression_no_in
  }
  # -- 11.9

  # 11.10 --
  rule(:bitwise_and_expression) {
    # equality_expression |
    #   bitwise_and_expression >> str('&') >> equality_expression
    (equality_expression >> spaces? >> str('&') >> spaces?).repeat >> equality_expression
  }
  rule(:bitwise_and_expression_no_in) {
    # equality_expression_no_in |
    #   bitwise_and_expression_no_in >> str('&') >> equality_expression_no_in
    (equality_expression_no_in >> spaces? >> str('&') >> spaces?).repeat >> equality_expression_no_in
  }
  rule(:bitwise_xor_expression) {
    # bitwise_and_expression |
    #   bitwise_xor_expression >> str('^') >> bitwise_and_expression
    (bitwise_and_expression >> spaces? >> str('^') >> spaces?).repeat >> bitwise_and_expression
  }
  rule(:bitwise_xor_expression_no_in) {
    # bitwise_and_expression_no_in |
    #   bitwise_xor_expression_no_in >> str('^') >> bitwise_and_expression_no_in
    (bitwise_and_expression_no_in >> spaces? >> str('^') >> spaces?).repeat >> bitwise_and_expression_no_in
  }
  rule(:bitwise_or_expression) {
    # bitwise_xor_expression |
    #   bitwise_or_expression >> str('|') >> bitwise_xor_expression
    (bitwise_xor_expression >> spaces? >> str('|') >> spaces?).repeat >> bitwise_xor_expression
  }
  rule(:bitwise_or_expression_no_in) {
    # bitwise_xor_expression_no_in |
    #   bitwise_or_expression_no_in >> str('|') >> bitwise_xor_expression_no_in
    (bitwise_xor_expression_no_in >> spaces? >> str('|') >> spaces?).repeat >> bitwise_xor_expression_no_in
  }
  # -- 11.10

  # 11.11 --
  rule(:logical_and_expression) {
    # bitwise_or_expression |
    #   logical_and_expression >> str('&&') >> bitwise_or_expression
    (bitwise_or_expression >> spaces? >> str('&&') >> spaces?).repeat >> bitwise_or_expression
  }
  rule(:logical_and_expression_no_in) {
    # bitwise_or_expression_no_in |
    #   logical_and_expression_no_in >> str('&&') >> bitwise_or_expression_no_in
    (bitwise_or_expression_no_in >> spaces? >> str('&&') >> spaces?).repeat >> bitwise_or_expression_no_in
  }
  rule(:logical_or_expression) {
    # logical_and_expression |
    #   logical_or_expression >> str('||') >> logical_and_expression
    (logical_and_expression >> spaces? >> str('||') >> spaces?).repeat >> logical_and_expression
  }
  rule(:logical_or_expression_no_in) {
    # logical_and_expression_no_in |
    #   logical_or_expression_no_in >> str('||') > logical_and_expression_no_in
    (logical_and_expression_no_in >> spaces? >> str('||') >> spaces?).repeat >> logical_and_expression_no_in
  }
  # -- 11.11

  # 11.12 --
  rule(:conditional_expression) {
    logical_or_expression |
      logical_or_expression >> spaces? >> str('?') >> spaces? >> assignment_expression >> spaces? >> str(':') >> spaces? >> assignment_expression
  }
  rule(:conditional_expression_no_in) {
    logical_or_expression_no_in |
      logical_or_expression_no_in >> spaces? >> str('?') >> spaces? >> assignment_expression >> spaces? >> str(':') >> spaces? >> assignment_expression_no_in
  }
  # -- 11.12

  # 11.13 --
  rule(:assignment_expression) {
    conditional_expression |
      left_hand_side_expression >> spaces? >> str('=') >> spaces? >> assignment_expression |
      left_hand_side_expression >> spaces? >> assignment_operator >> spaces? >> assignment_expression
  }
  rule(:assignment_expression_no_in) {
    conditional_expression_no_in |
      left_hand_side_expression >> spaces? >> str('=') >> spaces? >> assignment_expression_no_in |
      left_hand_side_expression >> spaces? >> assignment_operator >> spaces? >> assignment_expression_no_in
  }
  rule(:assignment_operator) {
    str('*=') | str('/=') | str('%=') | str('+=') | str('-=') |
      str('<<=') | str('>>=') | str('>>>=') | str('&=') | str('^=') | str('|=')
  }
  # -- 11.13

  # 11.14 --
  rule(:expression) {
    # assignment_expression |
    #   expression >> str(',') >> assignment_expression
    (assignment_expression >> spaces? >> str(',') >> spaces?).repeat >> assignment_expression
  }
  rule(:expression_no_in) {
    # assignment_expression_no_in |
    #   expression_no_in >> str(',') >> assignment_expression_no_in
    (assignment_expression_no_in >> spaces? >> str(',') >> spaces?).repeat >> assignment_expression_no_in
  }
  # -- 11.14

  # 12 --
  rule(:statement) {
    block |
      variable_statement |
      empty_statement |
      expression_statement |
      if_statement |
      iteration_statement |
      continue_statement |
      break_statement |
      return_statement |
      with_statement |
      labelled_statement |
      switch_statement |
      throw_statement |
      try_statement |
      debugger_statement
  }
  # -- 12

  # 12.1 --
  rule(:block) {
    str('{') >> spaces? >> statement_list.maybe >> spaces? >> str('}')
  }
  rule(:statement_list) {
    (statement >> spaces?).repeat(1)
  }
  # -- 12.1

  # 12.2 --
  rule(:variable_statement) {
    str('var') >> spaces? >> variable_declaration_list >> spaces? >> str(';')
  }
  rule(:variable_declaration_list) {
    (variable_declaration >> spaces? >> str(',')).repeat >> spaces? >> variable_declaration
  }
  rule(:variable_declaration_list_no_in) {
    (variable_declaration_no_in >> spaces? >> str(',')).repeat >> spaces? >> variable_declaration_no_in
  }
  rule(:variable_declaration) {
    identifier >> spaces? >> initialiser.maybe
  }
  rule(:variable_declaration_no_in) {
    identifier >> spaces? >> initialiser_no_in.maybe
  }
  rule(:initialiser) {
    str('=') >> spaces? >> assignment_expression
  }
  rule(:initialiser_no_in) {
    str('=') >> spaces? >> assignment_expression_no_in
  }
  # -- 12.2

  # 12.3 --
  rule(:empty_statement) {
    str(';')
  }
  # -- 12.3

  # 12.4 --
  rule(:expression_statement) {
    (str(',') | str('function')).absent? >> spaces? >> expression >> spaces? >> str(';')
  }
  # -- 12.4

  # 12.5 --
  rule(:if_statement) {
    str('if') >> spaces? >> str('(') >> spaces? >> expression >> spaces? >> str(')') >> spaces? >>
      statement >> (spaces? >> str('else') >> spaces? >> statement).maybe
  }
  # -- 12.5

  # 12.6 --
  rule(:iteration_statement) {
    str('do') >> spaces? >> statement >> spaces? >> str('while') >> spaces? >> str('(') >> spaces? >> expression >> spaces? >> str(')') >> spaces? >> str(';') |
      str('while') >> spaces? >> str('(') >> spaces? >> expression >> spaces? >> str(')') >> spaces >> statement |
      str('for') >> spaces? >> str('(') >> spaces? >> expression_no_in.maybe >> spaces? >> str(';') >> spaces? >> expression.maybe >> spaces? >> str(';') >> spaces? >> expression.maybe >> spaces? >> str(')') >> spaces? >> statement |
      str('for') >> spaces? >> str('(') >> spaces? >> str('var') >> spaces >> variable_declaration_list_no_in >> spaces? >> str(';') >> spaces? >> expression.maybe >> spaces? >> str(';') >> spaces? >> expression.maybe >> spaces? >> str(')') >> spaces? >> statement |
      str('for') >> spaces? >> str('(') >> spaces? >> left_hand_side_expression >> spaces >> str('in') >> spaces >> expression >> spaces? >> str(')') >> spaces? >> statement |
      str('for') >> spaces? >> str('(') >> spaces? >> str('var') >> spaces >> variable_declaration_no_in >> spaces >> str('in') >> spaces >> expression >> spaces? >> str(')') >> spaces? >> statement
  }
  # -- 12.6

  # 12.7 --
  rule(:continue_statement) {
    str('continue') >> spaces? >> str(';') |
      str('continue') >> spaces >> identifier >> spaces? >> str(';') # continue [no LineTerminator here] Identifier ;
  }
  # -- 12.7

  # 12.8 --
  rule(:break_statement) {
    str('break') >> spaces? >> str(';') |
      str('break') >> spaces >> identifier >> spaces? >> str(';') # break [no LineTerminator here] Identifier ;
  }
  # -- 12.8

  # 12.9 --
  rule(:return_statement) {
    str('return') >> spaces? >> str(';') |
      str('return') >> spaces >> expression >> spaces? >> str(';') # return [no LineTerminator here] Expression ;
  }
  # -- 12.9

  # 12.10 --
  rule(:with_statement) {
    str('with') >> spaces? >> str('(') >> spaces? >> expression >> spaces? >> str(')') >> spaces? >> statement
  }
  # -- 12.10

  # 12.11 --
  rule(:switch_statement) {
    str('switch') >> spaces? >> str('(') >> spaces? >> expression >> spaces? >> str(')') >> spaces? >> case_block
  }
  rule(:case_block) {
    str('{') >> spaces? >> case_clouses.maybe >> spaces? >> str('}') |
    str('{') >> spaces? >> case_clouses.maybe >> spaces? >> default_clause >> spaces? >> case_clauses.maybe >> spaces? >> str('}')
  }
  rule(:case_clauses) {
    (case_clause >> spaces?).repeat(1)
  }
  rule(:case_clause) {
    str('case') >> spaces >> expression >> spaces? >> str(':') >> spaces? >> statement_list.maybe
  }
  rule(:default_clause) {
    str('default') >> spaces? >> str(':') >> spaces? >> statement_list.maybe
  }
  # -- 12.11

  # 12.12 --
  rule(:labelled_statement) {
    identifier >> spaces? >> str(':') >> spaces? >> statement
  }
  #- 12.12

  # 12.13 --
  rule(:throw_statement) {
    str('throw') >> spaces >> expression >> spaces? >> str(';') # throw [no LineTerminator here] Expression ;
  }
  # -- 12.13

  # 12.14 --
  rule(:try_statement) {
    str('try') >> spaces? >> block >> spaces? >> catch |
      str('try') >> spaces? >> block >> spaces? >> finally |
      str('try') >> spaces? >> block >> spaces? >> catch >> spaces? >> finally
  }
  rule(:catch) {
    str('catch') >> spaces? >> str('(') >> spaces? >> identifier >> spaces? >> str(')') >> spaces? >> block
  }
  rule(:finally) {
    str('finally') >> spaces? >> block
  }
  # -- 12.14

  # 12.15 --
  rule(:debugger_statement) {
    str('debugger') >> spaces? >> str(';')
  }
  # -- 12.15

  # 13 --
  rule(:function_declaration) {
    str('function') >> spaces >> identifier >> spaces? >> str('(') >> spaces? >> formal_parameter_list.maybe >> spaces? >> str(')') >> spaces? >> str('{') >> spaces? >> function_body >> spaces? >> str('}')
  }
  rule(:function_expression) {
    str('function') >> (spaces >> identifier | spaces?) >> spaces? >> str('(') >> spaces? >> formal_parameter_list.maybe >> spaces? >> str(')') >> spaces? >> str('{') >> spaces? >> function_body >> spaces? >> str('}')
  }
  rule(:formal_parameter_list) {
    # identifier |
    #   formal_parameter_list >> str(',') >> identifier
    (identifier >> spaces? >> str(',') >> spaces?).repeat >> identifier
  }
  rule(:function_body) {
    spaces? >> source_elements.maybe >> spaces?
  }
  rule(:source_elements) {
    # source_element |
    #   source_elements >> source_element
    (source_element >> spaces?).repeat(1)
  }
  rule(:source_element) {
    statement |
      function_declaration
  }
  # -- 13
end

class ECMAScriptExpressionParser < ECMAScriptParser
  root(:cwl_expression)

  rule(:cwl_expression) {
    (str('$(').absent? >> any).repeat.as(:pre) >> str('$(') >> expression.as(:body) >> str(')') >> any.repeat.as(:post)
  }
end

class ECMAScriptFunctionBodyParser < ECMAScriptParser
  root(:cwl_function_body)

  rule(:cwl_function_body) {
    (str('${').absent? >> any).repeat.as(:pre) >> str('${') >> function_body.as(:body) >> str('}') >> any.repeat.as(:post)
  }
end

def test_exp(str)
  ECMAScriptExpressionParser.new.parse(str)
end

def test_fn(str)
  ECMAScriptFunctionBodyParser.new.parse(str)
end

if $0 == __FILE__
  p test_exp(ARGV.empty? ? '$([1,2,3])' : ARGV.first)
  # p test_fn(ARGV.empty? ? '${}' : ARGV.first)
end
