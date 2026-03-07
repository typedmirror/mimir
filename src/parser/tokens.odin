package parser

Binary_Op :: enum u8 {
	Add,
	Sub,
	Mult,
	Mat_Mult,
	Div,
	Mod,
	Pow,
	LShift,
	RShift,
	Bit_Or,
	Bit_Xor,
	Bit_And,
	Floor_Div,
}

Unary_Op :: enum u8 {
	Invert,
	Not,
	UAdd,
	USub,
}

Bool_Op_Kind :: enum u8 {
	And,
	Or,
}

Cmp_Op :: enum u8 {
	Eq,
	Not_Eq,
	Lt,
	Lt_E,
	Gt,
	Gt_E,
	Is,
	Is_Not,
	In,
	Not_In,
}

Expr_Context :: enum u8 {
	Load,
	Store,
	Del,
}
