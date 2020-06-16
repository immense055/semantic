{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- NOTE: This file needs to be updated to accommodate new AST shapes.
-- A portion of instances have been updated to include the Err functor;
-- remaining instances are to be updated once this is stable.

module Language.Python.ScopeGraph
  ( scopeGraphModule,
  )
where

import AST.Element
import qualified Analysis.Name as Name
import Control.Effect.ScopeGraph
import           AST.Element
import qualified AST.Parse as Parse
import           Control.Effect.ScopeGraph
import qualified Control.Effect.ScopeGraph.Properties.Declaration as Props
import Control.Effect.State
import Data.Bifunctor
import Data.Foldable
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.ScopeGraph as ScopeGraph
import qualified Data.Text as Text
import Data.Traversable
import Debug.Trace
import GHC.Records
import GHC.TypeLits
import qualified Language.Python.AST as Py
import Language.Python.Patterns
import Scope.Graph.Convert (Result (..), complete, todo)
import Scope.Types as Scope
import Source.Loc (Loc)
import Source.Span (Pos (..), point)
import qualified Stack.Graph as Stack
import Control.Monad ((<=<))


-- Utility function to avoid a dependency. Alternatively, we could import
-- Data.Either.Utils from MissingH or Data.Either.Extra from extra
fromEither :: Either a a -> a
fromEither = either id id

-- This typeclass is internal-only, though it shares the same interface
-- as the one defined in semantic-scope-graph. The somewhat-unconventional
-- quantified constraint is to avoid having to define Show1 instances for
-- every single Python AST type.
class (forall a. Show a => Show (t a)) => ToScopeGraph t where
  type FocalPoint (t :: * -> *) (a :: *)

  scopeGraph ::
    (ScopeGraphEff sig m) =>
    t Loc ->
    m (Result (FocalPoint t Loc))

instance (ToScopeGraph l, ToScopeGraph r) => ToScopeGraph (l :+: r) where
  type FocalPoint (l :+: r) a = Either (FocalPoint l a) (FocalPoint r a)
  scopeGraph (L1 l) = fmap Left <$> scopeGraph l
  scopeGraph (R1 r) = fmap Right <$> scopeGraph r

onField ::
  forall (field :: Symbol) syn sig m r.
  ( ScopeGraphEff sig m,
    HasField field (r Loc) (syn Loc),
    ToScopeGraph syn
  ) =>
  r Loc ->
  m (Result (FocalPoint syn Loc))
onField =
  scopeGraph @syn
    . getField @field

-- ([(node_for_the_name, ast_for_the_decl)], ...)
type ClassBodyBinder = Py.Assignment
                    :+: Py.AugmentedAssignment
                    :+: Py.FunctionDefinition
                    :+: Py.ClassDefinition
                    :+: Py.DecoratedDefinition

type BodyStruct a b = ([(Stack.Node, ClassBodyBinder a)], b)

noBindings :: b -> BodyStruct a b
noBindings x = ([],x)

scopeGraphModule :: ScopeGraphEff sig m => Py.Module Loc -> m (Result ())
scopeGraphModule x = fmap (const ()) <$> scopeGraph x

instance ToScopeGraph Py.AssertStatement where
  type FocalPoint Py.AssertStatement a = BodyStruct a [Stack.Node]
  scopeGraph assertStmt = todo assertStmt

-- fmap (\x -> [x]) <$> todo assertStmt

instance ToScopeGraph Py.Assignment where
  type FocalPoint Py.Assignment a = BodyStruct a Stack.Node
  scopeGraph asgn@(Py.Assignment _ _ Nothing _) =
    todo asgn
  scopeGraph asgn@(Py.Assignment ann (Parse.Success (SingleIdentifier identifier)) (Just (Parse.Success val)) _typ) = do
    -- TODO: What should we do with the type of an assignment?
    -- TODO: What should we do with the right hand side of an assignment?
    res <- scopeGraph val
    undefined
    -- let propagateThese = case res of
    --                        Complete (Left (Left (bindings, _)))   -> bindings
    --                        Complete (Left (Right (bindings, _)))  -> bindings
    --                        Complete (Right (Left (bindings, _)))  -> bindings
    --                        Complete (Right (Right (bindings, _))) -> bindings
    --                        -- TODO: Don't drop Todos
    --                        _ -> []
    --     decl = Stack.Declaration identifier Scope.Identifier ann
    -- pure (Complete ((decl,L1 asgn) : propagateThese, decl))
  scopeGraph x = todo x

instance ToScopeGraph Py.Await where
  type FocalPoint Py.Await a = BodyStruct a Stack.Node
  scopeGraph (Py.Await _ (Parse.Success a)) = scopeGraph a

instance ToScopeGraph Py.BooleanOperator where
  type FocalPoint Py.BooleanOperator a = BodyStruct a Stack.Node
  scopeGraph = todo -- (Py.BooleanOperator _ _ left right) = scopeGraph left <> scopeGraph right

instance ToScopeGraph Py.BinaryOperator where
  type FocalPoint Py.BinaryOperator a = BodyStruct a Stack.Node
  scopeGraph = todo -- (Py.BinaryOperator _ _ left right) = scopeGraph left <> scopeGraph right

instance ToScopeGraph Py.AugmentedAssignment where
  type FocalPoint Py.AugmentedAssignment a = BodyStruct a Stack.Node
  scopeGraph = todo

--(Py.AugmentedAssignment _ _ lhs rhs) = fmap _augmentedAssignment <$> onField @"right" x

instance ToScopeGraph Py.Attribute where
  type FocalPoint Py.Attribute a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Block where
  type FocalPoint Py.Block a = BodyStruct a [Stack.Node]
  scopeGraph (Py.Block _ statements) = do
    whatev <- mapM (scopeGraph <=< ensureAST) statements
    undefined
    -- let results = sequenceA whatev
    -- let res' = fmap (fmap fromEithers') results
    -- pure $ fmap (foldr (\oldBody (newBindings, newNodes) -> (newBindings <> fst oldBody, newNodes <> snd oldBody)) mempty) (res' :: Result [BodyStruct Loc [Stack.Node]])
    -- where
    --   fromEithers' ::
    --     Either
    --       ( Either
    --           ( Either
    --               (Either (BodyStruct Loc b) (BodyStruct Loc b))
    --               (Either (BodyStruct Loc b) (BodyStruct Loc b))
    --           )
    --           ( Either
    --               (Either (BodyStruct Loc b) (BodyStruct Loc b))
    --               (Either (BodyStruct Loc b) (BodyStruct Loc b))
    --           )
    --       )
    --       (BodyStruct Loc b) ->
    --     BodyStruct Loc b
    --   fromEithers' bodyStructs = (fromEither . first fromEither . first fromEither . first fromEither) bodyStructs

instance ToScopeGraph Py.BreakStatement where
  type FocalPoint Py.BreakStatement a = BodyStruct a [Stack.Node]
  scopeGraph statement = todo statement

instance ToScopeGraph Py.Call where
  type FocalPoint Py.Call a = BodyStruct a Stack.Node
  scopeGraph
    Py.Call
      { function = Parse.Success f,
        arguments = Parse.Success (L1 Py.ArgumentList {extraChildren = args})
      } = do
      _result <- scopeGraph f
      let scopeGraphArg = \case
            EPrj expr -> scopeGraph @Py.Expression expr
            other -> todo other
      _args <- traverse scopeGraphArg args
      pure (Todo ("Plz implement ScopeGraph.hs l164" :| [])) --(result <> mconcat args)
  scopeGraph it = todo it

instance ToScopeGraph Py.ClassDefinition where
  type FocalPoint Py.ClassDefinition a = BodyStruct a [Stack.Node]
  scopeGraph
    def@Py.ClassDefinition
      { ann,
        name = Parse.Success (Py.Identifier _ann1 name),
        superclasses = _superclasses,
        body = (Parse.Success b)
      } = do
      let name' = Name.name name

      CurrentScope currentScope' <- currentScope
      let declaration = (Stack.Declaration name' ScopeGraph.Class ann)
      modify (Stack.addEdge (Stack.Scope currentScope') declaration)
      modify (Stack.addEdge declaration (Stack.PopSymbol "()"))

      modify (Stack.addEdge (Stack.PopSymbol "()") (Stack.SelfScope "self"))
      modify (Stack.addEdge (Stack.SelfScope "self") (Stack.PopSymbol "."))
      modify (Stack.addEdge (Stack.PopSymbol ".") (Stack.InstanceMembers "IM"))
      modify (Stack.addEdge (Stack.InstanceMembers "IM") (Stack.ClassMembers "CM"))

      modify (Stack.addEdge declaration (Stack.PopSymbol "."))
      modify (Stack.addEdge (Stack.PopSymbol ".") (Stack.ClassMembers "CM"))

      -- TODO: Should we assert return nodes is empty here.
      res <- scopeGraph b
      case res of
        Complete (bindings, _) -> do
          for_ bindings $ \(node, statement) ->
            if isInstanceMember statement then
              modify (Stack.addEdge (Stack.InstanceMembers "IM") node)
            else if isClassMember statement then
              modify (Stack.addEdge (Stack.ClassMembers "CM") node)
            else pure ()
          pure ()
        -- TODO: Don't drop Todos or log.
        _ -> pure ()

      -- TODO: replace R1L1 with injection
      pure (Complete ([(declaration,R1 (R1 (R1 (L1 def))))], []))

      -- for_ bindings $ \(node, statement) -> do
      --   -- let callNode = Stack.PopSymbol "()"
      --   undefined

isInstanceMember :: ClassBodyBinder a -> Bool
isInstanceMember (Prj (Py.FunctionDefinition {})) = True
isInstanceMember _ = False

isClassMember :: ClassBodyBinder a -> Bool
isClassMember (Prj (Py.Assignment {})) = True
isClassMember (Prj (Py.ClassDefinition {})) = True
isClassMember (Prj (Py.DecoratedDefinition {})) = True
isClassMember _ = False

instance ToScopeGraph Py.ConcatenatedString where
  type FocalPoint Py.ConcatenatedString a = BodyStruct a Stack.Node
  scopeGraph = todo

deriving instance ToScopeGraph Py.CompoundStatement

instance ToScopeGraph Py.ConditionalExpression where
  type FocalPoint Py.ConditionalExpression a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ContinueStatement where
  type FocalPoint Py.ContinueStatement a = BodyStruct a [Stack.Node]
  scopeGraph _ = pure (Complete ([], []))

instance ToScopeGraph Py.DecoratedDefinition where
  type FocalPoint Py.DecoratedDefinition a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.ComparisonOperator where
  type FocalPoint Py.ComparisonOperator a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.DeleteStatement where
  type FocalPoint Py.DeleteStatement a = BodyStruct a [Stack.Node]
  scopeGraph _ = pure (Complete ([], []))

instance ToScopeGraph Py.Dictionary where
  type FocalPoint Py.Dictionary a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.DictionaryComprehension where
  type FocalPoint Py.DictionaryComprehension a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.DictionarySplat where
  type FocalPoint Py.DictionarySplat a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Expression where
  type FocalPoint Py.Expression a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ElseClause where
  type FocalPoint Py.ElseClause a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ElseClause _ (Parse.Success body)) = scopeGraph body

instance ToScopeGraph Py.ElifClause where
  type FocalPoint Py.ElifClause a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ElifClause _ (Parse.Success body) (Parse.Success condition)) = do
    _ <- scopeGraph condition
    scopeGraph body

instance ToScopeGraph Py.Ellipsis where
  type FocalPoint Py.Ellipsis a = BodyStruct a [Stack.Node]
  scopeGraph _ = pure (Complete ([], []))

instance ToScopeGraph Py.ExceptClause where
  type FocalPoint Py.ExceptClause a = BodyStruct a [Stack.Node]
  scopeGraph x = todo x

-- fmap (either (const []) id) <$> todo x

instance ToScopeGraph Py.ExecStatement where
  type FocalPoint Py.ExecStatement a = BodyStruct a [Stack.Node]
  scopeGraph x = do
    todo x

instance ToScopeGraph Py.ExpressionStatement where
  type FocalPoint Py.ExpressionStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ExpressionStatement _ eStatements) = do
    statements <- mapM ensureAST eStatements
    bindings <- for statements $ \stmt -> do
      res <- scopeGraph stmt
      undefined
      -- let flattenEithers = fst . fromEither . bimap fromEither fromEither
      -- case res of
      --   Complete r -> pure (flattenEithers r)
      --   _ -> pure []
    pure (Complete (concat (toList bindings), []))

instance ToScopeGraph Py.ExpressionList where
  type FocalPoint Py.ExpressionList a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.False where
  type FocalPoint Py.False a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.FinallyClause where
  type FocalPoint Py.FinallyClause a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.Float where
  type FocalPoint Py.Float a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ForStatement where
  type FocalPoint Py.ForStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.FunctionDefinition where
  type FocalPoint Py.FunctionDefinition a = BodyStruct a [Stack.Node]

  scopeGraph
    Py.FunctionDefinition
      { ann,
        name = Parse.Success (Py.Identifier _ann1 name),
        parameters = Parse.Success (Py.Parameters _ann2 parameters),
        body = Parse.Success b
      } = do
      let name' = Name.name name

      CurrentScope currentScope' <- currentScope
      let declaration = (Stack.Declaration name' ScopeGraph.Function ann)
      modify (Stack.addEdge (Stack.Scope currentScope') declaration)
      modify (Stack.addEdge declaration (Stack.PopSymbol "()"))

      let _declProps =
            Props.Declaration
              { Props.kind = ScopeGraph.Parameter,
                Props.relation = ScopeGraph.Default,
                Props.associatedScope = Nothing,
                Props.span = point (Pos 0 0)
              }
      let param (Py.Parameter (Prj (Py.Identifier pann pname))) = (pann, Name.name pname)
          param _ = error "Plz implement ScopeGraph.hs l223"
      parameters' <- mapM ensureAST parameters
      let parameterMs = fmap param parameters'

      -- Add the formal parameters scope pointing to each of the parameter nodes
      let formalParametersScope = Stack.Scope (Name.name "FormalParameters")
      for_ (zip [0 ..] parameterMs) $ \(ix, (pos, parameter)) -> do
        paramNode <- declareParameter parameter ix ScopeGraph.Parameter pos
        modify (Stack.addEdge formalParametersScope paramNode)

      -- Add the parent scope pointing to the formal parameters node
      let parentScopeName = Name.name (Text.pack "ParentScope" <> name)
          -- TODO: Should InternalScope take Lexical or Class? Is this an edge type?
          parentScope = Stack.InternalScope parentScopeName
      modify (Stack.addEdge parentScope formalParametersScope)

      -- Convert the body, using the parent scope name as the root scope
      returnNodesResult <- withScope parentScopeName $ scopeGraph b
      let callNode = Stack.PopSymbol "()"
      case returnNodesResult of
        Complete (_, nodes) -> do
          for_ nodes $ \node ->
            modify (Stack.addEdge callNode node)
        result -> do
          traceM (show result)
          pure ()

      -- Add the scope that contains the declared function name
      (functionNameNode, _associatedScope) <-
        declareFunction
          (Just name')
          ScopeGraph.Function
          ann

      modify (Stack.addEdge functionNameNode callNode)

      pure (Complete ([], []))

instance ToScopeGraph Py.FutureImportStatement where
  type FocalPoint Py.FutureImportStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.GeneratorExpression where
  type FocalPoint Py.GeneratorExpression a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Identifier where
  type FocalPoint Py.Identifier a = BodyStruct a Stack.Node
  scopeGraph (Py.Identifier ann name) = do
    node <- refer (Name.name name) ScopeGraph.Identifier ann
    pure (Complete (noBindings node))

instance ToScopeGraph Py.IfStatement where
  type FocalPoint Py.IfStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.IfStatement _ alternative (Parse.Success body) (Parse.Success condition)) = do
    _ <- scopeGraph condition
    res <- scopeGraph body
    reses <- mapM (scopeGraph <=< ensureAST) alternative
    pure (res <> mconcat (map (fmap fromEither) reses))

-- scopeGraph body <> (fmap fromEither <$> foldMap scopeGraph alternative)

instance ToScopeGraph Py.GlobalStatement where
  type FocalPoint Py.GlobalStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.Integer where
  type FocalPoint Py.Integer a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ImportStatement where
  type FocalPoint Py.ImportStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ImportStatement _ (Parse.Success (R1 (Py.DottedName _ eNames@(Parse.Success (Py.Identifier ann definition) :| _))) :| [])) = do
    rootScope' <- rootScope
    ScopeGraph.CurrentScope previousScope <- currentScope

    name <- Name.gensym

    names <- mapM ensureAST eNames
    let names' = (\(Py.Identifier ann name) -> (Name.name name, Identifier, ann)) <$> names
    childGraph <- addDeclarations names'
    let childGraph' = Stack.addEdge (Stack.Scope name) (Stack.Declaration (Name.name definition) Identifier ann) childGraph
    let childGraph'' = Stack.addEdge ((\(name, kind, ann) -> Stack.Reference name kind ann) (NonEmpty.head names')) rootScope' childGraph'

    modify (Stack.addEdge (Stack.Scope name) (Stack.Scope previousScope) . Stack.overlay childGraph'')

    putCurrentScope name

    complete
  scopeGraph term = todo (show term)

instance ToScopeGraph Py.ImportFromStatement where
  type FocalPoint Py.ImportFromStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ImportFromStatement _ [] (Parse.Success (L1 (Py.DottedName _ eNames))) (Just (Parse.Success (Py.WildcardImport _ _)))) = do
    let toName (Py.Identifier _ name) = Name.name name
    names <- mapM ensureAST eNames
    complete <* newEdge ScopeGraph.Import (toName <$> names)
  scopeGraph (Py.ImportFromStatement _ _imports (Parse.Success (L1 (Py.DottedName _ _names@(Parse.Success (Py.Identifier _ann _scopeName) :| _)))) Nothing) = do
    -- let toName (Py.Identifier _ name) = Name.name name
    -- newEdge ScopeGraph.Import (toName <$> names)

    -- let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann ^. span_ :: Span)
    -- newReference (Name.name scopeName) referenceProps

    -- let pairs = zip (toList names) (tail $ toList names)
    -- for_ pairs $ \pair -> do
    --   case pair of
    --     (scopeIdentifier, referenceIdentifier@(Py.Identifier ann2 _)) -> do
    --       withScope (toName scopeIdentifier) $ do
    --         let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann2 ^. span_ :: Span)
    --         newReference (toName referenceIdentifier) referenceProps

    -- completions <- for imports $ \identifier -> do
    --   case identifier of
    --     (R1 (Py.DottedName _ (Py.Identifier ann name :| []))) -> do
    --       let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann ^. span_ :: Span)
    --       complete <* newReference (Name.name name) referenceProps
    --     (L1 (Py.AliasedImport _ (Py.Identifier ann name) (Py.DottedName _ (Py.Identifier ann2 ref :| _)))) -> do
    --       let declProps = Props.Declaration ScopeGraph.UnqualifiedImport ScopeGraph.Default Nothing (ann ^. span_ :: Span)
    --       declare (Name.name name) declProps

    --       let referenceProps = Props.Reference ScopeGraph.Identifier ScopeGraph.Default (ann2 ^. span_ :: Span)
    --       newReference (Name.name ref) referenceProps

    --       complete
    --     (R1 (Py.DottedName _ ((Py.Identifier _ _) :| (_ : _)))) -> undefined

    -- pure (mconcat completions)
    todo ("Plz implement: ScopeGraph.hs l321" :: String)
  scopeGraph term = todo term

instance ToScopeGraph Py.Lambda where
  type FocalPoint Py.Lambda a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.List where
  type FocalPoint Py.List a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ListComprehension where
  type FocalPoint Py.ListComprehension a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.ListSplat where
  type FocalPoint Py.ListSplat a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.NamedExpression where
  type FocalPoint Py.NamedExpression a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.None where
  type FocalPoint Py.None a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.NonlocalStatement where
  type FocalPoint Py.NonlocalStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.Module where
  type FocalPoint Py.Module a = BodyStruct a ()
  scopeGraph _term@(Py.Module ann stmts) = do
    rootScope' <- rootScope

    putCurrentScope "__main__"

    modify (Stack.addEdge rootScope' (Stack.Declaration "__main__" Identifier ann))

    _ <- mapM (scopeGraph <=< ensureAST) stmts

    newGraph <- get @(Stack.Graph Stack.Node)

    ScopeGraph.CurrentScope currentName <- currentScope
    modify (Stack.addEdge (Stack.Declaration "__main__" Identifier ann) (Stack.Scope currentName) . Stack.overlay newGraph)

    pure (Complete (noBindings ()))

instance ToScopeGraph Py.ReturnStatement where
  type FocalPoint Py.ReturnStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.ReturnStatement _ maybeVals) = do
    let returnNode = Stack.Scope "R"
        res = Complete ([], [returnNode])
    case maybeVals of
      Just eVals -> do
        reses <- (scopeGraph <=< ensureAST) eVals
        case reses of
          Complete (_, nodes) -> do
            for_ nodes $ \node ->
              modify (Stack.addEdge returnNode node)
          _ -> pure ()

        pure res
      Nothing -> pure res

instance ToScopeGraph Py.True where
  type FocalPoint Py.True a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.NotOperator where
  type FocalPoint Py.NotOperator a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Pair where
  type FocalPoint Py.Pair a = BodyStruct a Stack.Node
  scopeGraph = todo -- (Py.Pair _ value key) = scopeGraph key <> scopeGraph value

instance ToScopeGraph Py.ParenthesizedExpression where
  type FocalPoint Py.ParenthesizedExpression a = BodyStruct a Stack.Node
  scopeGraph = todo

--onField @"extraChildren"

instance ToScopeGraph Py.PassStatement where
  type FocalPoint Py.PassStatement a = BodyStruct a [Stack.Node]
  scopeGraph _ = pure (Complete ([], []))

instance ToScopeGraph Py.PrintStatement where
  type FocalPoint Py.PrintStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

--(Py.PrintStatement _ args _chevron) = foldMap scopeGraph args

instance ToScopeGraph Py.PrimaryExpression where
  type FocalPoint Py.PrimaryExpression a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.SimpleStatement where
  type FocalPoint Py.SimpleStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.SimpleStatement stmt) =
    undefined
    -- fmap (either (either (either id fromEither)
    --                      (either fromEither fromEither))
    --              (either (either fromEither fromEither)
    --                      (either fromEither fromEither)))
    --   <$> (scopeGraph stmt)

instance ToScopeGraph Py.RaiseStatement where
  type FocalPoint Py.RaiseStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.Set where
  type FocalPoint Py.Set a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.SetComprehension where
  type FocalPoint Py.SetComprehension a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.String where
  type FocalPoint Py.String a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Subscript where
  type FocalPoint Py.Subscript a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.Tuple where
  type FocalPoint Py.Tuple a = BodyStruct a Stack.Node
  scopeGraph = todo

instance ToScopeGraph Py.TryStatement where
  type FocalPoint Py.TryStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.TryStatement _ eBody eClauses) = do
    body <- ensureAST eBody
    res <- scopeGraph body
    elseClauses <- mapM ensureAST eClauses
    reses <- mapM scopeGraph elseClauses
    pure (res <> mconcat (map (fmap (either id fromEither)) (toList reses)))

--scopeGraph body <> (_tryStatement (foldMap scopeGraph elseClauses))

instance ToScopeGraph Py.UnaryOperator where
  type FocalPoint Py.UnaryOperator a = BodyStruct a Stack.Node
  scopeGraph = todo

--onField @"argument"

instance ToScopeGraph Py.WhileStatement where
  type FocalPoint Py.WhileStatement a = BodyStruct a [Stack.Node]
  scopeGraph (Py.WhileStatement _ (Just eAlternative) (Parse.Success body) (Parse.Success condition)) = do
    _ <- scopeGraph condition
    res <- scopeGraph body

    reses <- (scopeGraph <=< ensureAST) eAlternative
    pure (res <> reses)
  scopeGraph x = todo x

instance ToScopeGraph Py.WithStatement where
  type FocalPoint Py.WithStatement a = BodyStruct a [Stack.Node]
  scopeGraph = todo

instance ToScopeGraph Py.Yield where
  type FocalPoint Py.Yield a = BodyStruct a Stack.Node
  scopeGraph = todo
