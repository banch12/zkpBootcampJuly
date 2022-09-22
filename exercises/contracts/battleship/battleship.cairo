%lang starknet
from starkware.cairo.common.cairo_builtins import HashBuiltin, BitwiseBuiltin
from starkware.cairo.common.uint256 import Uint256, uint256_le, uint256_unsigned_div_rem, uint256_sub
from starkware.starknet.common.syscalls import get_caller_address
from starkware.cairo.common.math import unsigned_div_rem, assert_le_felt, assert_le
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.hash_state import hash_init, hash_update
from starkware.cairo.common.bitwise import bitwise_and, bitwise_xor

struct Square:
    member square_commit: felt
    member square_reveal: felt
    member shot: felt
end

struct Player:
    member address: felt
    member points: felt
    member revealed: felt
end

struct Game:
    member player1: Player
    member player2: Player
    member next_player: felt
    member last_move: (felt, felt)
    member winner: felt
end


@storage_var
func grid(game_idx : felt, player : felt, x : felt, y : felt) -> (square : Square):
end

@storage_var
func games(game_idx : felt) -> (game_struct : Game):
end

@storage_var
func game_counter() -> (game_counter : felt):
end

func hash_numb{pedersen_ptr : HashBuiltin*}(numb : felt) -> (hash : felt):

    alloc_locals

    let (local array : felt*) = alloc()
    assert array[0] = numb
    assert array[1] = 1
    let (hash_state_ptr) = hash_init()
    let (hash_state_ptr) = hash_update{hash_ptr=pedersen_ptr}(hash_state_ptr, array, 2)
    tempvar pedersen_ptr :HashBuiltin* = pedersen_ptr
    return (hash_state_ptr.current_hash)
end


## Provide two addresses
#The function set_up_game is the first one to be called by whoever wants to set up a game, and it accepts two players' addresses.
#It will read the current game index from game_counter, create a struct Game with addresses of the players (everything else set to zero) and finally will write it to the games mapping.
#Finally, this function will increment the game_counter by one.
## To check: Does this function need game_counter and games as arguments???
@external
func set_up_game{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(player1 : felt, player2 : felt):

    let p1 = Player(player1, 0, 0)
    let p2 = Player(player2, 0, 0)

    # read current game index
    let (cur_game_idx) = game_counter.read()

    # create a struct Game with addr of the players
    # might need to alloc() mem for game_inst
    let game_inst = Game(
                          player1 = p1,
                          player2 = p2,
                          next_player= 0,
                          last_move= (0, 0),
                          winner= 0
                        )

    # write to game mapping
    games.write(cur_game_idx, game_inst)

    # write it to game mapping
    game_counter.write(cur_game_idx + 1)

    return ()
end


@view
func check_caller{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(caller : felt, game : Game) -> (valid : felt):
    # perhaps need to use get_caller_address() here
    if caller == game.player1.address:
        return (valid=1)
    else:
       if caller == game.player2.address:
          return(valid=1)
       else:
          return (valid=0)
       end
    end
end


# func check_hit
#The function check_hit checks whether previously invoked bombardment has hit the square containing a ship.
#It receives square_commit and square_reveal.
#It will assert re-hashed square_reveal matches square_commit to make sure player provided the rigth solution and is not lying.
#After that check, the square_reveal is checked to see if it the ship is there.
#If the number is even, there is no ship. If it is odd, the ship is located there and a hit has been scored.
#Return 1 for a hit, and 0 for a miss.
@view
func check_hit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(square_commit : felt, square_reveal : felt) -> (hit : felt):

   # re-hash the square_reveal
   let (rehashed_square_reveal) = hash_numb(square_reveal)

   # compare re-hashed square_reveal to square_commit
   assert rehashed_square_reveal = square_commit

   # check square_reveal is even or odd.  If odd, hit=1, else hit=0
   let (q, r) = unsigned_div_rem(value=square_reveal, div=2)
   if r == 0:
      return(hit=0)
   else:
      return(hit=1)
   end
end


# x, y: position to hit
# square_reveal: reveal for the previous hit by other player
@external
func bombard{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr, bitwise_ptr: BitwiseBuiltin*}(game_idx : felt, x : felt, y : felt, square_reveal : felt):

    alloc_locals

    #check whether the caller is one of the players and whether it is their move (first move can be by anyone).
    #get address of the caller
    let (caller) = get_caller_address()
    let (current_game) = games.read(game_idx=game_idx)
    #  check caller
    let (valid_player) = check_caller(caller=caller, game=current_game)
    with_attr error_message("Not a Valid Player"):
        assert 1 = valid_player
    end
    #check who is the caller
    let player1 = current_game.player1.address
    let player2 = current_game.player2.address
    local current_player
    local other_player
    local winner


    if caller == player1:
        current_player = caller
        other_player = player2
    else:
        current_player = caller
        other_player = player1
    end

    # set Square marked as hit by the current caller (using x/y cords provided as arguments)
    let (square_curr_player) = grid.read(game_idx=game_idx, player=caller, x=x, y=y)
    let updated_square = Square(
                                square_curr_player.square_commit,
                                square_curr_player.square_reveal,
                                1
                               )

    grid.write(game_idx, caller, x, y, updated_square)

    # check points and set winner
    if current_game.player1.points == 4:
        winner = player1
    else:
        if current_game.player2.points == 4:
            winner = player2
        else:
            winner = current_game.winner
        end
    end

        let updated_game = Game(
                            current_game.player1,
                            current_game.player2,
                            current_game.next_player,
                            (x, y),
                            winner
                           )
    games.write(game_idx, updated_game)


    # check if this is first move.
    # # This can be accomplished by checking next_player, if it is not set, then this is
    # # very first move
    # # For very first move, set the next_player as the other player
    # this is very first move, no need to process square_reveal
    if current_game.next_player == 0:
        let updated_game = Game(
                                current_game.player1,
                                current_game.player2,
                                other_player,
                                (x, y),
                                current_game.winner
                               )
        games.write(game_idx, updated_game)
        return ()
    else:
            # not a very first move, need to process square_reveal
        # check if the move belong to caller
        with_attr error_message("Not your turn"):
            assert caller = current_game.next_player
        end

        # set the next_player as other player
        let updated_game = Game(
                                current_game.player1,
                                current_game.player2,
                                other_player,
                                (x, y),
                                current_game.winner
                               )
        games.write(game_idx, updated_game)

        #process the square_reveal of the previous player -->  check_hit
        ## how to get square_comit needed for check_hit
        ## perhaps load the Square using grid.read
        ### get the Square of game.last_move
        ### for this, using game_idx, get last_move(x,y). Feed this (x,y) to grid.read to get Square
        ### Use Square.square_commit for check_hit


        let x_lastMove = current_game.last_move[0]
        let y_lastMove = current_game.last_move[1]
        # prev player is other player (next_player)
        let (square_prev_player) = grid.read(game_idx=game_idx, player=current_game.next_player, x=x_lastMove, y=y_lastMove)
        let square_commit_prev_player = square_prev_player.square_commit
        # now call check_hit to check whether previous player had a hit
        let (hit_by_prev_player) = check_hit(square_commit=square_commit_prev_player, square_reveal=square_reveal)
        if hit_by_prev_player == 1:
                                    # if hit by opposing player, increase points
                                    # increasing points is  bit complecated. To look into this
            # get the oppostite players and its points
                        if caller == current_game.player2.address:
               # previous player was player1
               let cur_pts_prev_player1 = current_game.player1.points
               let player1_updated_pts = cur_pts_prev_player1 + 1
               let player1_obj = Player(current_game.player1.address, player1_updated_pts, current_game.player1.revealed)
               let x_p2 = current_game.last_move[0]
               let y_p2= current_game.last_move[0]
               let updated_game = Game(
                                  player1_obj,
                                  current_game.player2,
                                  current_game.next_player,
                                  (x_p2, y_p2),
                                  current_game.winner
                                 )
               games.write(game_idx, updated_game)
               return ()
            else:
                           # previous player was player2
               let cur_pts_prev_player2 = current_game.player2.points
               let player2_updated_pts = cur_pts_prev_player2 + 1
               let player2_obj = Player(current_game.player2.address, player2_updated_pts, current_game.player2.revealed)
               let x_p1 = current_game.last_move[0]
               let y_p1= current_game.last_move[0]
               let updated_game = Game(
                                  current_game.player1,
                                  player2_obj,
                                  current_game.next_player,
                                  (x_p1, y_p1),
                                  current_game.winner
                                 )
               games.write(game_idx, updated_game)
               return ()
            end
        end
    end



    return()
end


## Check malicious call
@external
func add_squares{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(idx : felt, game_idx : felt, hashes_len : felt, hashes : felt*, player : felt, x: felt, y: felt):

    # check validity of caller by calling check caller
    # revert if valid_player == 0 --> To look into this
    ## with_attr function???
    #get game structure for the supplied game_idx
    let (current_game) = games.read(game_idx=game_idx)
    let (caller) = get_caller_address()

    let (valid_player) = check_caller(caller=caller, game=current_game)
    with_attr error_message("Not a Valid Player"):
      assert 1 = valid_player
    end
    # call load_hashes
    load_hashes(idx, game_idx, hashes_len, hashes, player, x, y)
    return ()
end


## loops until array length
func load_hashes{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(idx : felt, game_idx : felt, hashes_len : felt, hashes : felt*, player : felt, x: felt, y: felt):

    if hashes_len == 0:
       return()
    end

    let (cur_square) = grid.read(game_idx, player, x, y)
    let hashEntryCurIndex = [hashes]
    let updated_square = Square(hashEntryCurIndex, cur_square.square_reveal, cur_square.shot)
    grid.write(game_idx, player, x, y, updated_square)

    if x == 4:
        # call recursively. When X has reashed 4, reset to x to 0
        load_hashes(idx, game_idx, hashes_len-1, hashes+1, player, x=0, y=y+1)
    else:
        # call recursively. When x is less than 4, keep incrementing x with constant y
        load_hashes(idx, game_idx, hashes_len-1, hashes+1, player, x=x+1, y=y)
    end

    return ()
end