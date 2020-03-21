{- Michaels EVE Online mining bot version 2020-03-10
   The bot warps to an asteroid belt, mines there until the ore hold is full, and then docks at a station to unload the ore. It then repeats this cycle until you stop it.
   It remembers the station in which it was last docked, and docks again at the same station.
   Setup instructions for the EVE Online client:
   + Set the UI language to English.
   + In Overview window, make asteroids visible.
   + Set the Overview window to sort objects in space by distance with the nearest entry at the top.
   + Setup inventory window so that 'Ore Hold' is always selected.
   + In the ship UI, arrange the modules:
     + Place all mining modules (to activate on targets) in the top row.
     + Place modules that should always be active in the middle row.
     + Hide passive modules by disabling the check-box `Display Passive Modules`.
   + Enable the info panel 'System info'.
-}
{-
   bot-catalog-tags:eve-online,mining
   authors-forum-usernames:viir
-}


module Bot exposing
    ( State
    , initState
    , processEvent
    )

import BotEngine.Interface_To_Host_20200213 as InterfaceToHost
import EveOnline.BotFramework exposing (BotEffect(..), getEntropyIntFromUserInterface)
import EveOnline.MemoryReading
    exposing
        ( MaybeVisible(..)
        , OverviewWindowEntry
        , ParsedUserInterface
        , centerFromDisplayRegion
        , maybeNothingFromCanNotSeeIt
        , maybeVisibleAndThen
        )
import EveOnline.ParseUserInterface exposing (ShipUIModulesGroupedIntoRows)
import EveOnline.VolatileHostInterface as VolatileHostInterface exposing (MouseButton(..), effectMouseClickAtLocation)


runAwayShieldHitpointsThresholdPercent : Int
runAwayShieldHitpointsThresholdPercent =
    98


type alias UIElement =
    EveOnline.MemoryReading.UITreeNodeWithDisplayRegion


type alias TreeLeafAct =
    { firstAction : VolatileHostInterface.EffectOnWindowStructure
    , followingSteps : List ( String, ParsedUserInterface -> Maybe VolatileHostInterface.EffectOnWindowStructure )
    }


type EndDecisionPathStructure
    = Wait
    | Act TreeLeafAct


type DecisionPathNode
    = DescribeBranch String DecisionPathNode
    | EndDecisionPath EndDecisionPathStructure


type alias BotState =
    { programState :
        Maybe
            { decision : DecisionPathNode
            , lastStepIndexInSequence : Int
            }
    , botMemory : BotMemory
    }


type alias BotMemory =
    { lastDockedStationNameFromInfoPanel : Maybe String
    }


type alias State =
    EveOnline.BotFramework.StateIncludingFramework BotState


generalStepDelayMilliseconds : Int
generalStepDelayMilliseconds =
    2000


{-| A first outline of the decision tree for a mining bot is coming from <https://forum.botengine.org/t/how-to-automate-mining-asteroids-in-eve-online/628/109?u=viir>
-}
decideNextAction : BotMemory -> ParsedUserInterface -> DecisionPathNode
decideNextAction botMemory parsedUserInterface =
    if parsedUserInterface |> isShipWarpingOrJumping then
        -- TODO: Look also on the previous memory reading.
        DescribeBranch "I see we are warping." (EndDecisionPath Wait)

    else
        -- TODO: For robustness, also look also on the previous memory reading. Only continue when both indicate is undocked.
        case parsedUserInterface.shipUI of
            CanNotSeeIt ->
                DescribeBranch "I see no ship UI, assume we are docked." (decideNextActionWhenDocked parsedUserInterface)

            CanSee shipUI ->
                if shipUI.hitpointsPercent.shield < runAwayShieldHitpointsThresholdPercent then
                    DescribeBranch "Shield hitpoints are too low, run away." (runAway botMemory parsedUserInterface)

                else
                    case shipUI |> EveOnline.ParseUserInterface.groupShipUIModulesIntoRows of
                        Nothing ->
                            DescribeBranch "Failed to group the ship UI modules into rows." (EndDecisionPath Wait)

                        Just groupedShipModules ->
                            DescribeBranch "I see we are in space." (decideNextActionWhenInSpace botMemory groupedShipModules parsedUserInterface)


decideNextActionWhenDocked : ParsedUserInterface -> DecisionPathNode
decideNextActionWhenDocked parsedUserInterface =
    case parsedUserInterface |> inventoryWindowItemHangar of
        Nothing ->
            DescribeBranch "I do not see the item hangar in the inventory." (EndDecisionPath Wait)

        Just itemHangar ->
            case parsedUserInterface |> inventoryWindowSelectedContainerFirstItem of
                Nothing ->
                    DescribeBranch "I see no item in the ore hold. Time to undock."
                        (case parsedUserInterface |> activeShipUiElementFromInventoryWindow of
                            Nothing ->
                                EndDecisionPath Wait

                            Just activeShipEntry ->
                                EndDecisionPath
                                    (Act
                                        { firstAction =
                                            activeShipEntry
                                                |> clickLocationOnInventoryShipEntry
                                                |> effectMouseClickAtLocation MouseButtonRight
                                        , followingSteps =
                                            [ ( "Click menu entry 'undock'."
                                              , lastContextMenuOrSubmenu
                                                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Undock")
                                                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
                                              )
                                            ]
                                        }
                                    )
                        )

                Just itemInInventory ->
                    DescribeBranch "I see at least one item in the ore hold. Move this to the item hangar."
                        (EndDecisionPath
                            (Act
                                { firstAction =
                                    VolatileHostInterface.SimpleDragAndDrop
                                        { startLocation = itemInInventory.totalDisplayRegion |> centerFromDisplayRegion
                                        , endLocation = itemHangar.totalDisplayRegion |> centerFromDisplayRegion
                                        , mouseButton = MouseButtonLeft
                                        }
                                , followingSteps = []
                                }
                            )
                        )


decideNextActionWhenInSpace : BotMemory -> ShipUIModulesGroupedIntoRows -> ParsedUserInterface -> DecisionPathNode
decideNextActionWhenInSpace botMemory shipUIModules parsedUserInterface =
    case shipUIModules.middle |> List.filter (.isActive >> Maybe.withDefault False >> not) |> List.head of
        Just inactiveModule ->
            DescribeBranch "I see an inactive module in the middle row. Click on it to activate."
                (EndDecisionPath
                    (Act
                        { firstAction = inactiveModule.uiNode |> clickOnUIElement MouseButtonLeft
                        , followingSteps = []
                        }
                    )
                )

        Nothing ->
            case parsedUserInterface |> oreHoldFillPercent of
                Nothing ->
                    DescribeBranch "I cannot see the ore hold capacity gauge." (EndDecisionPath Wait)

                Just fillPercent ->
                    if 99 <= fillPercent then
                        DescribeBranch "The ore hold is full enough. Dock to station."
                            (case botMemory.lastDockedStationNameFromInfoPanel of
                                Nothing ->
                                    DescribeBranch "At which station should I dock?. I was never docked in a station in this session." (EndDecisionPath Wait)

                                Just lastDockedStationNameFromInfoPanel ->
                                    dockToStationMatchingNameSeenInInfoPanel
                                        { stationNameFromInfoPanel = lastDockedStationNameFromInfoPanel }
                                        parsedUserInterface
                            )

                    else
                        DescribeBranch "The ore hold is not full enough yet. Get more ore."
                            (case parsedUserInterface.targets |> List.head of
                                Nothing ->
                                    DescribeBranch "I see no locked target." (decideNextActionAcquireLockedTarget parsedUserInterface)

                                Just _ ->
                                    DescribeBranch "I see a locked target."
                                        (case shipUIModules.top |> List.filter (.isActive >> Maybe.withDefault False >> not) |> List.head of
                                            -- TODO: Check previous memory reading too for module activity.
                                            Nothing ->
                                                DescribeBranch "All mining laser modules are active." (EndDecisionPath Wait)

                                            Just inactiveModule ->
                                                DescribeBranch "I see an inactive mining module. Click on it to activate."
                                                    (EndDecisionPath
                                                        (Act
                                                            { firstAction = inactiveModule.uiNode |> clickOnUIElement MouseButtonLeft
                                                            , followingSteps = []
                                                            }
                                                        )
                                                    )
                                        )
                            )


decideNextActionAcquireLockedTarget : ParsedUserInterface -> DecisionPathNode
decideNextActionAcquireLockedTarget parsedUserInterface =
    case parsedUserInterface |> topmostAsteroidFromOverviewWindow of
        Nothing ->
            DescribeBranch "I see no asteroid in the overview. Warp to mining site."
                (warpToMiningSite parsedUserInterface)

        Just asteroidInOverview ->
            case asteroidInOverview.distanceInMeters of
                Ok asteroidDistanceInMeters ->
                    if asteroidDistanceInMeters < 8000 then
                        DescribeBranch "Asteroid is in range. Lock target."
                            (EndDecisionPath
                                (Act
                                    { firstAction = asteroidInOverview.uiNode |> clickOnUIElement MouseButtonRight
                                    , followingSteps =
                                        [ ( "Click menu entry 'lock'."
                                          , lastContextMenuOrSubmenu
                                                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "lock")
                                                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
                                          )
                                        ]
                                    }
                                )
                            )

                    else
                        DescribeBranch ("Asteroid is not in range (" ++ (asteroidDistanceInMeters |> String.fromInt) ++ " meters away). Approach.")
                            (EndDecisionPath
                                (Act
                                    { firstAction = asteroidInOverview.uiNode |> clickOnUIElement MouseButtonRight
                                    , followingSteps =
                                        [ ( "Click menu entry 'approach'."
                                          , lastContextMenuOrSubmenu
                                                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "approach")
                                                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
                                          )
                                        ]
                                    }
                                )
                            )

                Err error ->
                    DescribeBranch ("Failed to read the distance of the asteroid: " ++ error) (EndDecisionPath Wait)


dockToStationMatchingNameSeenInInfoPanel : { stationNameFromInfoPanel : String } -> ParsedUserInterface -> DecisionPathNode
dockToStationMatchingNameSeenInInfoPanel { stationNameFromInfoPanel } =
    dockToStationUsingSurroundingsButtonMenu
        ( "Click on menu entry representing the station '" ++ stationNameFromInfoPanel ++ "'."
        , List.filter (menuEntryMatchesStationNameFromLocationInfoPanel stationNameFromInfoPanel)
            >> List.head
        )


dockToStationUsingSurroundingsButtonMenu :
    ( String, List EveOnline.MemoryReading.ContextMenuEntry -> Maybe EveOnline.MemoryReading.ContextMenuEntry )
    -> ParsedUserInterface
    -> DecisionPathNode
dockToStationUsingSurroundingsButtonMenu ( describeChooseStation, chooseStationMenuEntry ) =
    useContextMenuOnListSurroundingsButton
        [ ( "Click on menu entry 'stations'."
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "stations")
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
          )
        , ( describeChooseStation
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (.entries >> chooseStationMenuEntry)
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
          )
        , ( "Click on menu entry 'dock'"
          , lastContextMenuOrSubmenu
                >> Maybe.andThen (menuEntryContainingTextIgnoringCase "dock")
                >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
          )
        ]


warpToMiningSite : ParsedUserInterface -> DecisionPathNode
warpToMiningSite parsedUserInterface =
    parsedUserInterface
        |> useContextMenuOnListSurroundingsButton
            [ ( "Click on menu entry 'asteroid belts'."
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "asteroid belts")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
              )
            , ( "Click on one of the menu entries."
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen
                        (.entries >> listElementAtWrappedIndex (getEntropyIntFromUserInterface parsedUserInterface))
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
              )
            , ( "Click menu entry 'Warp to Within'"
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Warp to Within")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
              )
            , ( "Click menu entry 'Within 20 km'"
              , lastContextMenuOrSubmenu
                    >> Maybe.andThen (menuEntryContainingTextIgnoringCase "Within 20 km")
                    >> Maybe.map (.uiNode >> clickOnUIElement MouseButtonLeft)
              )
            ]


runAway : BotMemory -> ParsedUserInterface -> DecisionPathNode
runAway botMemory parsedUserInterface =
    case botMemory.lastDockedStationNameFromInfoPanel of
        Nothing ->
            dockToRandomStation parsedUserInterface

        Just lastDockedStationNameFromInfoPanel ->
            dockToStationMatchingNameSeenInInfoPanel
                { stationNameFromInfoPanel = lastDockedStationNameFromInfoPanel }
                parsedUserInterface


dockToRandomStation : ParsedUserInterface -> DecisionPathNode
dockToRandomStation parsedUserInterface =
    dockToStationUsingSurroundingsButtonMenu
        ( "Pick random station.", listElementAtWrappedIndex (getEntropyIntFromUserInterface parsedUserInterface) )
        parsedUserInterface


useContextMenuOnListSurroundingsButton : List ( String, ParsedUserInterface -> Maybe VolatileHostInterface.EffectOnWindowStructure ) -> ParsedUserInterface -> DecisionPathNode
useContextMenuOnListSurroundingsButton followingSteps parsedUserInterface =
    case parsedUserInterface.infoPanelLocationInfo of
        CanNotSeeIt ->
            DescribeBranch "I cannot see the location info panel." (EndDecisionPath Wait)

        CanSee infoPanelLocationInfo ->
            EndDecisionPath
                (Act
                    { firstAction = infoPanelLocationInfo.listSurroundingsButton |> clickOnUIElement MouseButtonLeft
                    , followingSteps = followingSteps
                    }
                )


initState : State
initState =
    EveOnline.BotFramework.initState
        { programState = Nothing
        , botMemory = { lastDockedStationNameFromInfoPanel = Nothing }
        }


processEvent : InterfaceToHost.BotEvent -> State -> ( State, InterfaceToHost.BotResponse )
processEvent =
    EveOnline.BotFramework.processEvent processEveOnlineBotEvent


processEveOnlineBotEvent :
    EveOnline.BotFramework.BotEventContext
    -> EveOnline.BotFramework.BotEvent
    -> BotState
    -> ( BotState, EveOnline.BotFramework.BotEventResponse )
processEveOnlineBotEvent eventContext event stateBefore =
    case event of
        EveOnline.BotFramework.MemoryReadingCompleted parsedUserInterface ->
            let
                botMemory =
                    stateBefore.botMemory |> integrateCurrentReadingsIntoBotMemory parsedUserInterface

                programStateBefore =
                    stateBefore.programState
                        |> Maybe.withDefault { decision = decideNextAction botMemory parsedUserInterface, lastStepIndexInSequence = 0 }

                ( decisionStagesDescriptions, decisionLeaf ) =
                    unpackToDecisionStagesDescriptionsAndLeaf programStateBefore.decision

                ( currentStepDescription, effectsOnGameClientWindow, programState ) =
                    case decisionLeaf of
                        Wait ->
                            ( "Wait", [], Nothing )

                        Act act ->
                            let
                                programStateAdvancedToNextStep =
                                    { programStateBefore
                                        | lastStepIndexInSequence = programStateBefore.lastStepIndexInSequence + 1
                                    }

                                stepsIncludingFirstAction =
                                    ( "", always (Just act.firstAction) ) :: act.followingSteps
                            in
                            case stepsIncludingFirstAction |> List.drop programStateBefore.lastStepIndexInSequence |> List.head of
                                Nothing ->
                                    ( "Completed sequence.", [], Nothing )

                                Just ( stepDescription, effectOnGameClientWindowFromUserInterface ) ->
                                    case parsedUserInterface |> effectOnGameClientWindowFromUserInterface of
                                        Nothing ->
                                            ( "Failed step: " ++ stepDescription, [], Nothing )

                                        Just effect ->
                                            ( stepDescription, [ effect ], Just programStateAdvancedToNextStep )

                effectsRequests =
                    effectsOnGameClientWindow |> List.map EveOnline.BotFramework.EffectOnGameClientWindow

                describeActivity =
                    (decisionStagesDescriptions ++ [ currentStepDescription ])
                        |> List.indexedMap
                            (\decisionLevel -> (++) (("+" |> List.repeat (decisionLevel + 1) |> String.join "") ++ " "))
                        |> String.join "\n"

                statusMessage =
                    [ parsedUserInterface |> describeUserInterfaceForMonitoring, describeActivity ]
                        |> String.join "\n"
            in
            ( { stateBefore | botMemory = botMemory, programState = programState }
            , EveOnline.BotFramework.ContinueSession
                { effects = effectsRequests
                , millisecondsToNextReadingFromGame = generalStepDelayMilliseconds
                , statusDescriptionText = statusMessage
                }
            )


describeUserInterfaceForMonitoring : ParsedUserInterface -> String
describeUserInterfaceForMonitoring parsedUserInterface =
    let
        describeShip =
            case parsedUserInterface.shipUI of
                CanSee shipUI ->
                    "I am in space, shield HP at " ++ (shipUI.hitpointsPercent.shield |> String.fromInt) ++ "%."

                CanNotSeeIt ->
                    case parsedUserInterface.infoPanelLocationInfo |> maybeVisibleAndThen .expandedContent |> maybeNothingFromCanNotSeeIt |> Maybe.andThen .currentStationName of
                        Just stationName ->
                            "I am docked at '" ++ stationName ++ "'."

                        Nothing ->
                            "I cannot see if I am docked or in space. Please set up game client first."

        describeOreHold =
            "Ore hold filled " ++ (parsedUserInterface |> oreHoldFillPercent |> Maybe.map String.fromInt |> Maybe.withDefault "Unknown") ++ "%."
    in
    [ describeShip, describeOreHold ] |> String.join " "


integrateCurrentReadingsIntoBotMemory : ParsedUserInterface -> BotMemory -> BotMemory
integrateCurrentReadingsIntoBotMemory currentReading botMemoryBefore =
    let
        currentStationNameFromInfoPanel =
            currentReading.infoPanelLocationInfo
                |> maybeVisibleAndThen .expandedContent
                |> maybeNothingFromCanNotSeeIt
                |> Maybe.andThen .currentStationName
    in
    { lastDockedStationNameFromInfoPanel =
        [ currentStationNameFromInfoPanel, botMemoryBefore.lastDockedStationNameFromInfoPanel ]
            |> List.filterMap identity
            |> List.head
    }


unpackToDecisionStagesDescriptionsAndLeaf : DecisionPathNode -> ( List String, EndDecisionPathStructure )
unpackToDecisionStagesDescriptionsAndLeaf node =
    case node of
        EndDecisionPath leaf ->
            ( [], leaf )

        DescribeBranch branchDescription childNode ->
            let
                ( childDecisionsDescriptions, leaf ) =
                    unpackToDecisionStagesDescriptionsAndLeaf childNode
            in
            ( branchDescription :: childDecisionsDescriptions, leaf )


activeShipUiElementFromInventoryWindow : ParsedUserInterface -> Maybe UIElement
activeShipUiElementFromInventoryWindow =
    .inventoryWindows
        >> List.head
        >> Maybe.map .leftTreeEntries
        -- Assume upmost entry is active ship.
        >> Maybe.andThen (List.sortBy (.uiNode >> .totalDisplayRegion >> .y) >> List.head)
        >> Maybe.map .uiNode


{-| Returns the menu entry containing the string from the parameter `textToSearch`.
If there are multiple such entries, these are sorted by the length of their text, minus whitespaces in the beginning and the end.
The one with the shortest text is returned.
-}
menuEntryContainingTextIgnoringCase : String -> EveOnline.MemoryReading.ContextMenu -> Maybe EveOnline.MemoryReading.ContextMenuEntry
menuEntryContainingTextIgnoringCase textToSearch =
    .entries
        >> List.filter (.text >> String.toLower >> String.contains (textToSearch |> String.toLower))
        >> List.sortBy (.text >> String.trim >> String.length)
        >> List.head


{-| The names are at least sometimes displayed different: 'Moon 7' can become 'M7'
-}
menuEntryMatchesStationNameFromLocationInfoPanel : String -> EveOnline.MemoryReading.ContextMenuEntry -> Bool
menuEntryMatchesStationNameFromLocationInfoPanel stationNameFromInfoPanel menuEntry =
    (stationNameFromInfoPanel |> String.toLower |> String.replace "moon " "m")
        == (menuEntry.text |> String.trim |> String.toLower)


lastContextMenuOrSubmenu : ParsedUserInterface -> Maybe EveOnline.MemoryReading.ContextMenu
lastContextMenuOrSubmenu =
    .contextMenus >> List.head


topmostAsteroidFromOverviewWindow : ParsedUserInterface -> Maybe OverviewWindowEntry
topmostAsteroidFromOverviewWindow =
    overviewWindowEntriesRepresentingAsteroids
        >> List.sortBy (.uiNode >> .totalDisplayRegion >> .y)
        >> List.head


overviewWindowEntriesRepresentingAsteroids : ParsedUserInterface -> List OverviewWindowEntry
overviewWindowEntriesRepresentingAsteroids =
    .overviewWindow
        >> maybeNothingFromCanNotSeeIt
        >> Maybe.map (.entries >> List.filter overviewWindowEntryRepresentsAnAsteroid)
        >> Maybe.withDefault []


overviewWindowEntryRepresentsAnAsteroid : OverviewWindowEntry -> Bool
overviewWindowEntryRepresentsAnAsteroid entry =
    (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "asteroid"))
        && (entry.textsLeftToRight |> List.any (String.toLower >> String.contains "belt") |> not)


oreHoldFillPercent : ParsedUserInterface -> Maybe Int
oreHoldFillPercent =
    .inventoryWindows
        >> List.head
        >> Maybe.andThen .selectedContainerCapacityGauge
        >> Maybe.andThen Result.toMaybe
        >> Maybe.andThen
            (\capacity -> capacity.maximum |> Maybe.map (\maximum -> capacity.used * 100 // maximum))


inventoryWindowSelectedContainerFirstItem : ParsedUserInterface -> Maybe UIElement
inventoryWindowSelectedContainerFirstItem =
    .inventoryWindows
        >> List.head
        >> Maybe.andThen .selectedContainerInventory
        >> Maybe.andThen .itemsView
        >> Maybe.map
            (\itemsView ->
                case itemsView of
                    EveOnline.MemoryReading.InventoryItemsListView { items } ->
                        items

                    EveOnline.MemoryReading.InventoryItemsNotListView { items } ->
                        items
            )
        >> Maybe.andThen List.head


inventoryWindowItemHangar : ParsedUserInterface -> Maybe UIElement
inventoryWindowItemHangar =
    .inventoryWindows
        >> List.head
        >> Maybe.map .leftTreeEntries
        >> Maybe.andThen (List.filter (.text >> String.toLower >> String.contains "item hangar") >> List.head)
        >> Maybe.map .uiNode


clickOnUIElement : MouseButton -> UIElement -> VolatileHostInterface.EffectOnWindowStructure
clickOnUIElement mouseButton uiElement =
    effectMouseClickAtLocation mouseButton (uiElement.totalDisplayRegion |> centerFromDisplayRegion)


{-| The region of a ship entry in the inventory window can contain child nodes (e.g. 'Ore Hold').
For this reason, we don't click on the center but stay close to the top.
-}
clickLocationOnInventoryShipEntry : UIElement -> VolatileHostInterface.Location2d
clickLocationOnInventoryShipEntry uiElement =
    { x = uiElement.totalDisplayRegion.x + uiElement.totalDisplayRegion.width // 2
    , y = uiElement.totalDisplayRegion.y + 7
    }


isShipWarpingOrJumping : ParsedUserInterface -> Bool
isShipWarpingOrJumping =
    .shipUI
        >> maybeNothingFromCanNotSeeIt
        >> Maybe.andThen (.indication >> maybeNothingFromCanNotSeeIt)
        >> Maybe.andThen (.maneuverType >> maybeNothingFromCanNotSeeIt)
        >> Maybe.map
            (\maneuverType ->
                [ EveOnline.MemoryReading.ManeuverWarp, EveOnline.MemoryReading.ManeuverJump ]
                    |> List.member maneuverType
            )
        -- If the ship is just floating in space, there might be no indication displayed.
        >> Maybe.withDefault False


listElementAtWrappedIndex : Int -> List element -> Maybe element
listElementAtWrappedIndex indexToWrap list =
    if (list |> List.length) < 1 then
        Nothing

    else
        list |> List.drop (indexToWrap |> modBy (list |> List.length)) |> List.head
