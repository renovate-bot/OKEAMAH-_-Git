/******************************************************************************/
/*                                                                            */
/* SPDX-License-Identifier: MIT                                               */
/* Copyright (c) [2023] Serokell <hi@serokell.io>                             */
/*                                                                            */
/******************************************************************************/

use crate::ast::*;
use crate::stack::*;
use std::collections::VecDeque;

/// Typechecker error type.
#[derive(Debug, PartialEq, Eq)]
pub enum TcError {
    GenericTcError,
    StackTooShort,
    StacksNotEqual,
}

impl From<StackTooShort> for TcError {
    fn from(_: StackTooShort) -> Self {
        TcError::StackTooShort
    }
}

impl From<StacksNotEqual> for TcError {
    fn from(_: StacksNotEqual) -> Self {
        TcError::StacksNotEqual
    }
}

pub fn typecheck(ast: &AST, stack: &mut TypeStack) -> Result<(), TcError> {
    for i in ast {
        typecheck_instruction(&i, stack)?;
    }
    Ok(())
}

fn typecheck_instruction(i: &Instruction, stack: &mut TypeStack) -> Result<(), TcError> {
    use Instruction::*;
    use Type::*;

    match i {
        Add => match stack.make_contiguous() {
            [Type::Nat, Type::Nat, ..] => {
                stack.pop_front();
            }
            [Type::Int, Type::Int, ..] => {
                stack.pop_front();
            }
            _ => unimplemented!(),
        },
        Dip(opt_height, nested) => {
            let protected_height: usize = opt_height.unwrap_or(1);

            ensure_stack_len(stack, protected_height)?;
            // Here we split the stack into protected and live segments, and after typechecking
            // nested code with the live segment, we append the protected and the potentially
            // modified live segment as the result stack.
            let mut live = stack.split_off(protected_height);
            typecheck(nested, &mut live)?;
            stack.append(&mut live);
        }
        Drop(opt_height) => {
            let drop_height: usize = opt_height.unwrap_or(1);
            ensure_stack_len(&stack, drop_height)?;
            *stack = stack.split_off(drop_height);
        }
        Dup(Some(0)) => {
            // DUP instruction requires an argument that is > 0.
            return Err(TcError::GenericTcError);
        }
        Dup(opt_height) => {
            let dup_height: usize = opt_height.unwrap_or(1);
            ensure_stack_len(stack, dup_height)?;
            stack.push_front(stack.get(dup_height - 1).unwrap().to_owned());
        }
        Gt => match stack.make_contiguous() {
            [Type::Int, ..] => {
                stack[0] = Type::Bool;
            }
            _ => return Err(TcError::GenericTcError),
        },
        If(nested_t, nested_f) => match stack.make_contiguous() {
            // Check if top is bool and bind the tail to `t`.
            [Type::Bool, t @ ..] => {
                // Clone the stack so that we have two stacks to run
                // the two branches with.
                let mut t_stack: TypeStack = VecDeque::from(t.to_owned());
                let mut f_stack: TypeStack = VecDeque::from(t.to_owned());
                typecheck(nested_t, &mut t_stack)?;
                typecheck(nested_f, &mut f_stack)?;
                // If both stacks are same after typecheck, then make result
                // stack using one of them and return success.
                ensure_stacks_eq(t_stack.make_contiguous(), f_stack.make_contiguous())?;
                *stack = t_stack;
            }
            _ => return Err(TcError::GenericTcError),
        },
        Instruction::Int => match stack.make_contiguous() {
            [val @ Type::Nat, ..] => {
                *val = Type::Int;
            }
            _ => return Err(TcError::GenericTcError),
        },
        Loop(nested) => match stack.make_contiguous() {
            // Check if top is bool and bind the tail to `t`.
            [Bool, t @ ..] => {
                let mut live: TypeStack = VecDeque::from(t.to_owned());
                // Clone the tail and typecheck the nested body using it.
                typecheck(nested, &mut live)?;
                match live.make_contiguous() {
                    // ensure the result stack has a bool on top.
                    [Bool, r @ ..] => {
                        // If the starting tail and result tail match
                        // then the typecheck is complete. pop the bool
                        // off the original stack to form the final result.
                        ensure_stacks_eq(&t, &r)?;
                        stack.pop_front();
                    }
                    _ => return Err(TcError::GenericTcError),
                }
            }
            _ => return Err(TcError::GenericTcError),
        },
        Push(t, v) => {
            typecheck_value(&t, &v)?;
            stack.push_front(t.to_owned());
        }
        Swap => {
            ensure_stack_len(stack, 2)?;
            stack.swap(0, 1);
        }
    }
    Ok(())
}

fn typecheck_value(t: &Type, v: &Value) -> Result<(), TcError> {
    use Type::*;
    use Value::*;
    match (t, v) {
        (Nat, NumberValue(n)) if *n >= 0 => Ok(()),
        (Int, NumberValue(_)) => Ok(()),
        (Bool, BooleanValue(_)) => Ok(()),
        _ => Err(TcError::GenericTcError),
    }
}

#[cfg(test)]
mod typecheck_tests {
    use std::collections::VecDeque;

    use crate::parser::*;
    use crate::typechecker::*;
    use Instruction::*;

    #[test]
    fn test_dup() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Nat, Type::Nat]);
        typecheck_instruction(&Dup(Some(1)), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_dup_n() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat, Type::Int]);
        typecheck_instruction(&Dup(Some(2)), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_swap() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat]);
        typecheck_instruction(&Swap, &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_int() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Int]);
        typecheck_instruction(&Int, &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_drop() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([]);
        typecheck(&parse("{DROP}").unwrap(), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_drop_n() {
        let mut stack = VecDeque::from([Type::Nat, Type::Int]);
        let expected_stack = VecDeque::from([]);
        typecheck_instruction(&Drop(Some(2)), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_push() {
        let mut stack = VecDeque::from([Type::Nat]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat]);
        typecheck_instruction(&Push(Type::Int, Value::NumberValue(1)), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_gt() {
        let mut stack = VecDeque::from([Type::Int]);
        let expected_stack = VecDeque::from([Type::Bool]);
        typecheck_instruction(&Gt, &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_dip() {
        let mut stack = VecDeque::from([Type::Int, Type::Bool]);
        let expected_stack = VecDeque::from([Type::Int, Type::Nat, Type::Bool]);
        typecheck_instruction(&Dip(Some(1), parse("{PUSH nat 6}").unwrap()), &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_add() {
        let mut stack = VecDeque::from([Type::Int, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int]);
        typecheck_instruction(&Add, &mut stack).unwrap();
        assert!(stack == expected_stack);
    }

    #[test]
    fn test_loop() {
        let mut stack = VecDeque::from([Type::Bool, Type::Int]);
        let expected_stack = VecDeque::from([Type::Int]);
        assert!(
            typecheck_instruction(&Loop(parse("{PUSH bool True}").unwrap()), &mut stack).is_ok()
        );
        assert!(stack == expected_stack);
    }
}
